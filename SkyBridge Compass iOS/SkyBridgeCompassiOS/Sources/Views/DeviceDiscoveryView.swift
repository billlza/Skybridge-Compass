import SwiftUI

/// 设备发现视图 - 发现和连接其他设备（iOS/macOS/其他平台）
@available(iOS 17.0, *)
struct DeviceDiscoveryView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    
    @State private var isScanning = false
    @State private var selectedDevice: DiscoveredDevice?
    @State private var showConnectionSheet = false
    @State private var searchText = ""
    
    // iPad 自适应布局
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景
                backgroundGradient
                
                // 主内容
                if discoveryManager.discoveredDevices.isEmpty {
                    emptyStateView
                } else {
                    deviceListView
                }
            }
            .navigationTitle("设备发现")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
#endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    scanButton
                }
            }
            .searchable(text: $searchText, prompt: "搜索设备...")
            .sheet(item: $selectedDevice) { device in
                DeviceDetailSheet(device: device)
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.15),
                Color(red: 0.1, green: 0.1, blue: 0.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // 图标
            Image(systemName: "wifi.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue.gradient)
            
            // 标题
            Text("没有发现设备")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            // 说明
            Text("点击右上角扫描按钮开始发现附近的设备")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            // 扫描按钮
            Button(action: startScanning) {
                Label("开始扫描", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(.blue.gradient)
                    .cornerRadius(12)
            }
            .disabled(isScanning)
            
            Spacer()
        }
    }
    
    // MARK: - Device List
    
    private var deviceListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredDevices) { device in
                    DeviceRowView(
                        device: device,
                        connectionStatus: connectionManager.connectionStatusByDeviceId[device.id]
                    ) {
                        selectedDevice = device
                    }
                }
            }
            .padding()
        }
    }
    
    private var filteredDevices: [DiscoveredDevice] {
        if searchText.isEmpty {
            return discoveryManager.discoveredDevices
        } else {
            return discoveryManager.discoveredDevices.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.modelName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // MARK: - Scan Button
    
    private var scanButton: some View {
        Button(action: startScanning) {
            Image(systemName: isScanning ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundColor(isScanning ? .red : .blue)
        }
    }
    
    // MARK: - Actions
    
    private func startScanning() {
        isScanning.toggle()
        
        if isScanning {
            Task {
                do {
                    try await discoveryManager.startDiscovery()
                    SkyBridgeLogger.shared.info("📡 开始扫描设备...")
                } catch {
                    SkyBridgeLogger.shared.error("❌ 扫描失败: \(error.localizedDescription)")
                    isScanning = false
                }
            }
        } else {
            discoveryManager.stopDiscovery()
            SkyBridgeLogger.shared.info("⏹️ 停止扫描")
        }
    }
}


// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(RuntimeLocalization.string(label))
                .foregroundColor(.gray)
            
            Spacer()
            
            Text(value)
                .foregroundColor(.white)
                .font(.system(.body, design: .monospaced))
        }
        .font(.subheadline)
    }
}

// MARK: - Preview
#if DEBUG
struct DeviceDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceDiscoveryView()
            .environmentObject(DeviceDiscoveryManager.instance)
            .environmentObject(P2PConnectionManager.instance)
    }
}
#endif
