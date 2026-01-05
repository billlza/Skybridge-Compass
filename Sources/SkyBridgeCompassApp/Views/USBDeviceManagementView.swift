import SwiftUI
import SkyBridgeCore

/// USB设备管理视图
/// 展示已连接的USB设备，包括MFi认证设备、Android设备、硬盘和U盘
@available(macOS 14.0, *)
struct USBDeviceManagementView: View {
    @StateObject private var usbManager = USBCConnectionManager()
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @State private var connectedDevices: [USBDeviceInfo] = []
    @State private var isScanning = false
    @State private var lastScanTime: Date?
    
    var body: some View {
        NavigationView {
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
        .onAppear {
            refreshDevices()
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
    
    private func refreshDevices() {
        isScanning = true
        
        Task {
 // 扫描MFi设备
            await usbManager.scanForMFiDevices()
            
 // 扫描USB设备
            await usbManager.scanForUSBDevices()
            
 // 获取设备列表
            let devices = usbManager.getConnectedUSBDevices()
            
            await MainActor.run {
                self.connectedDevices = devices.sorted { $0.name < $1.name }
                self.lastScanTime = Date()
                self.isScanning = false
            }
        }
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
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
