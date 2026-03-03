import SwiftUI

@available(iOS 17.0, *)
struct RadarScanOverlay: View {
    @State private var rotation = 0.0
    @State private var pulse = false
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
                .frame(width: pulse ? 400 : 50, height: pulse ? 400 : 50)
                .opacity(pulse ? 0 : 1)
            
            Circle()
                .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
                .frame(width: pulse ? 600 : 50, height: pulse ? 600 : 50)
                .opacity(pulse ? 0 : 1)
                .animation(.easeOut(duration: 2).delay(0.5).repeatForever(autoreverses: false), value: pulse)
            
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [Color.clear, Color.cyan.opacity(0.05), Color.cyan.opacity(0.2)]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(90)
                    )
                )
                .rotationEffect(.degrees(rotation))
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotation = 360.0
            }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

@available(iOS 17.0, *)
struct DeviceDiscoveryView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    
    @State private var selectedDevice: DiscoveredDevice?
    @State private var showConnectionSheet = false
    @State private var searchText = ""
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    scanStatusHeader
                    
                    if discoveryManager.discoveredDevices.isEmpty {
                        emptyStateView
                    } else {
                        deviceListContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(DashboardView.QuantumGlassBackground())
            .scrollContentBackground(.hidden)
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
    
    // MARK: - Scan Status Header
    
    private var scanStatusHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isScanning ? Color.cyan.opacity(0.15) : Color.white.opacity(0.05))
                    .frame(width: 48, height: 48)
                
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isScanning ? .cyan : .white.opacity(0.5))
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(isScanning ? "正在扫描..." : "设备扫描")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                
                Text(isScanning
                     ? "发现 \(discoveryManager.discoveredDevices.count) 台设备"
                     : "点击右上角开始扫描附近设备")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
            
            if isScanning {
                ProgressView()
                    .tint(.cyan)
                    .scaleEffect(0.8)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [isScanning ? Color.cyan.opacity(0.4) : Color.white.opacity(0.15), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 60)
            
            ZStack {
                if isScanning {
                    RadarScanOverlay()
                        .frame(width: 200, height: 200)
                }
                
                Image(systemName: "wifi.circle")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.cyan.opacity(0.6))
            }
            .frame(height: 200)
            
            Text(isScanning ? "正在搜索附近设备..." : "暂无发现设备")
                .font(.title3.weight(.medium))
                .foregroundColor(.white.opacity(0.8))
            
            Text("请确保目标设备在同一网络，或已开启跨网发现")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if !isScanning {
                Button(action: startScanning) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("开始扫描")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(Capsule())
                }
            }
            
            Spacer().frame(height: 60)
        }
    }
    
    // MARK: - Device List
    
    private var deviceListContent: some View {
        LazyVStack(spacing: 10) {
            ForEach(filteredDevices) { device in
                DeviceRowView(
                    device: device,
                    connectionStatus: connectionManager.connectionStatusByDeviceId[device.id]
                ) {
                    selectedDevice = device
                }
            }
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

    private var isScanning: Bool {
        discoveryManager.isDiscovering
    }
    
    // MARK: - Scan Button
    
    private var scanButton: some View {
        Button(action: startScanning) {
            Image(systemName: isScanning ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundColor(isScanning ? .red : .cyan)
        }
    }
    
    // MARK: - Actions
    
    private func startScanning() {
        if isScanning {
            discoveryManager.stopDiscovery()
            SkyBridgeLogger.shared.info("⏹️ 停止扫描")
            return
        }

        Task {
            do {
                try await discoveryManager.startDiscovery()
                SkyBridgeLogger.shared.info("📡 开始扫描设备...")
            } catch {
                SkyBridgeLogger.shared.error("❌ 扫描失败: \(error.localizedDescription)")
            }
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
