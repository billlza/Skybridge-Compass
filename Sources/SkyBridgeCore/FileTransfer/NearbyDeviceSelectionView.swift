import SwiftUI
import UniformTypeIdentifiers

/// 近距设备选择视图 - 用于文件传输
/// 集成设备发现管理器，显示附近可用的设备
/// 支持旧版和优化版的DeviceDiscoveryManager
public struct NearbyDeviceSelectionView: View {
    @ObservedObject var deviceDiscoveryManager: DeviceDiscoveryManagerOptimized  // 2025年优化版
    let selectedFiles: [URL]
    let onDeviceSelected: (DiscoveredDevice, [URL]) -> Void  // 修改回调签名，传递文件列表
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedDevice: DiscoveredDevice?
    @State private var searchText = ""
    @State private var localSelectedFiles: [URL] = []
    @State private var showingFilePicker = false
    
    public init(
        deviceDiscoveryManager: DeviceDiscoveryManagerOptimized,  // 2025年优化版
        selectedFiles: [URL],
        onDeviceSelected: @escaping (DiscoveredDevice, [URL]) -> Void  // 修改回调签名
    ) {
        self.deviceDiscoveryManager = deviceDiscoveryManager
        self.selectedFiles = selectedFiles
        self.onDeviceSelected = onDeviceSelected
        self._localSelectedFiles = State(initialValue: selectedFiles)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
 // 顶部标题栏
            headerSection
            
            Divider()
            
 // 文件选择区域
            if localSelectedFiles.isEmpty {
                fileSelectionPrompt
            } else {
                selectedFilesPreview
            }
            
            Divider()
            
 // 搜索栏
            searchBar
            
 // 设备列表
            if filteredDevices.isEmpty {
                emptyStateView
            } else {
                deviceList
            }
            
 // 底部操作按钮
            bottomActions
        }
        .frame(width: 700, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingFilePicker) {
            FilePickerView { urls in
                localSelectedFiles = urls
            }
        }
        .onAppear {
            deviceDiscoveryManager.startScanning()
        }
        .onDisappear {
            deviceDiscoveryManager.stopScanning()
        }
    }
    
 // MARK: - 子视图
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("发送到附近设备")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if !localSelectedFiles.isEmpty {
                    Text("将 \(localSelectedFiles.count) 个文件发送到附近的设备")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("选择要发送的文件和目标设备")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if deviceDiscoveryManager.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("扫描中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Button(action: {
                deviceDiscoveryManager.startScanning()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新设备列表")
        }
        .padding(20)
    }
    
    private var fileSelectionPrompt: some View {
        Button(action: {
            showingFilePicker = true
        }) {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                
                Text("选择要发送的文件")
                    .font(.headline)
                
                Text("点击选择文件或拖拽文件到此处")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.blue.opacity(0.05))
        }
        .buttonStyle(.plain)
    }
    
    private var selectedFilesPreview: some View {
        VStack(spacing: 8) {
            HStack {
                Text("已选择 \(localSelectedFiles.count) 个文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("重新选择") {
                    showingFilePicker = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(localSelectedFiles, id: \.path) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                            
                            Text(file.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 12)
        }
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索设备...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    private var filteredDevices: [DiscoveredDevice] {
        if searchText.isEmpty {
            return deviceDiscoveryManager.discoveredDevices
        } else {
            return deviceDiscoveryManager.discoveredDevices.filter { device in
                device.name.localizedCaseInsensitiveContains(searchText) ||
                (device.ipv4 ?? "").contains(searchText) ||
                (device.ipv6 ?? "").contains(searchText)
            }
        }
    }
    
    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredDevices, id: \.id) { device in
                    DeviceSelectionCard(
                        device: device,
                        isSelected: selectedDevice?.id == device.id
                    ) {
                        selectedDevice = device
                    }
                }
            }
            .padding(20)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: deviceDiscoveryManager.isScanning ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(deviceDiscoveryManager.isScanning ? "正在搜索设备..." : "未发现设备")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("确保设备在同一网络并开启文件传输服务")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            if !deviceDiscoveryManager.isScanning {
                Button("重新扫描") {
                    deviceDiscoveryManager.startScanning()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private var bottomActions: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button("发送") {
                if let device = selectedDevice, !localSelectedFiles.isEmpty {
 // 使用本地选择的文件
                    sendFilesToDevice(device: device, files: localSelectedFiles)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedDevice == nil || localSelectedFiles.isEmpty)
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
 // MARK: - 辅助方法
    
 /// 发送文件到设备（内部处理，避免循环调用）
    private func sendFilesToDevice(device: DiscoveredDevice, files: [URL]) {
 // 调用回调，传递设备和文件列表
        onDeviceSelected(device, files)
    }
}

// MARK: - 设备选择卡片
struct DeviceSelectionCard: View {
    let device: DiscoveredDevice
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceColor)
                    .frame(width: 40, height: 40)
                    .background(deviceColor.opacity(0.1))
                    .clipShape(Circle())
                
 // 设备信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 4) {
                        if let ipv4 = device.ipv4 {
                            Text(ipv4)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if !device.services.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(device.services.count) 个服务")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
 // 选中指示器
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var deviceIcon: String {
 // 根据服务类型判断设备类型
        if device.services.contains(where: { $0.contains("airplay") }) {
            return "appletvremote.fill"
        } else if device.services.contains(where: { $0.contains("companion") }) {
            return "iphone"
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return "desktopcomputer"
        } else {
            return "laptopcomputer"
        }
    }
    
    private var deviceColor: Color {
        if device.services.contains(where: { $0.contains("airplay") }) {
            return .purple
        } else if device.services.contains(where: { $0.contains("companion") }) {
            return .blue
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return .green
        } else {
            return .gray
        }
    }
}

// MARK: - 文件选择器
struct FilePickerView: View {
    let onFilesSelected: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("选择文件")
                .font(.title2)
                .fontWeight(.semibold)
            
            Button("选择文件") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                
                if panel.runModal() == .OK {
                    onFilesSelected(panel.urls)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("取消") {
                dismiss()
            }
        }
        .padding(40)
        .frame(width: 400, height: 200)
    }
}

