import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

                    AdvertisingLifecycleBanner(
                        state: connectionManager.advertisingLifecycle,
                        isBrowseAuthorizationBlocked: discoveryManager.isBrowseAuthorizationBlocked
                    )

                    if let notice = connectionManager.inboundConnectionNotice {
                        InboundConnectionNoticeBanner(notice: notice) {
                            connectionManager.dismissInboundConnectionNotice()
                        }
                    }

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
                    connectionStatus: connectionManager.resolvedConnectionStatus(for: device)
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


// MARK: - Advertising Lifecycle Banner

/// Surfaces why this device is (not) discoverable by peers.
///
/// Advertising used to fail silently, which is indistinguishable from "nobody is nearby".
/// The pending local-network permission case is the one blocker only the user can clear,
/// so it gets an explicit action instead of a log line.
struct AdvertisingLifecycleBanner: View {
    let state: P2PConnectionManager.AdvertisingLifecycleState
    /// Denied local-network access blocks browsing too, so it is reported here rather than leaving
    /// the device list silently empty.
    let isBrowseAuthorizationBlocked: Bool

    var body: some View {
        if isBrowseAuthorizationBlocked {
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "需要允许「本地网络」访问",
                detail: """
                未获授权时既看不到附近设备，本机也无法被发现。请在「设置 › 隐私与安全性 › \
                本地网络」中允许 SkyBridge；授权后会自动重试。
                """,
                action: ("打开系统设置", openSystemSettings)
            )
        } else {
            advertisingBanner
        }
    }

    @ViewBuilder
    private var advertisingBanner: some View {
        switch state {
        case .idle, .advertising:
            EmptyView()

        case .blockedByStartupFailure(let reason):
            banner(
                icon: "xmark.octagon.fill",
                tint: .red,
                title: "本机广播已停用",
                detail: """
                设备身份未就绪，为避免广播未绑定的身份，本机不会被其他设备发现（仍会继续查找附近设备）。\
                原因：\(reason)
                """,
                action: nil
            )

        case .starting:
            banner(
                icon: "antenna.radiowaves.left.and.right",
                tint: .cyan,
                title: "正在开启本机广播…",
                detail: "其他设备暂时还看不到这台设备。",
                action: nil
            )

        case .awaitingLocalNetworkAuthorization(let nextRetryInSeconds):
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "需要允许「本地网络」访问",
                detail: """
                未获授权时本机无法被其他设备发现。请在「设置 › 隐私与安全性 › 本地网络」中\
                允许 SkyBridge；授权后约 \(Int(nextRetryInSeconds)) 秒内会自动恢复广播。
                """,
                action: ("打开系统设置", openSystemSettings)
            )

        case .retrying(let attempt, let nextRetryInSeconds):
            banner(
                icon: "arrow.triangle.2.circlepath",
                tint: .yellow,
                title: "本机广播正在重试（第 \(attempt) 次）",
                detail: "将在约 \(Int(nextRetryInSeconds)) 秒后重试，恢复前其他设备看不到这台设备。",
                action: nil
            )
        }
    }

    @ViewBuilder
    private func banner(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        action: (title: String, handler: () -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                if let action {
                    Button(action.title, action: action.handler)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(tint)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(detail))
    }

    private func openSystemSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }
}

// MARK: - Inbound Connection Notice Banner

/// Surfaces a refused or failed inbound connection.
///
/// The shared inbound-admission contract (`InboundHandshakeTrustPolicy`) forbids
/// silent drops: whenever the responder closes an inbound handshake, the reason
/// must reach the operator. This banner is that surface on iOS.
struct InboundConnectionNoticeBanner: View {
    let notice: P2PConnectionManager.InboundConnectionNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("入站连接未建立")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                Text(notice.occurredAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("关闭入站连接通知"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("入站连接未建立"))
        .accessibilityValue(Text(notice.message))
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
