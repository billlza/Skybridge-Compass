import SwiftUI
import SkyBridgeCore

/// 近距硬件镜像视图 - iPhone 镜像风格
/// 自动发现 + 一键连接，无需手动输入
///
/// macOS 15/26 最佳实践：
/// 注：macOS Tahoe 26 已于 2025-09-15 正式发布，并在 CryptoKit 与 TLS 栈中提供官方的 Post-quantum HPKE（X-Wing）、ML-KEM、ML-DSA 支持
/// - 独立窗口（WindowGroup），不是模态对话框
/// - 支持标准窗口操作（最小化、全屏、关闭）
/// - 可以与主窗口并存
struct NearFieldMirrorView: View {
    @StateObject private var discoveryManager = DeviceDiscoveryManagerOptimized() // 高性能设备发现（2025年优化版）
    @StateObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared
 // 近距镜像会话控制管理器（硬件级远程控制）
 // 注：RemoteControlManager 负责接收远端屏幕数据与输入事件处理，这里只负责启动/停止控制会话。
    @StateObject private var remoteControlManager = RemoteControlManager()
    @State private var selectedDevice: DiscoveredDevice?
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var currentDeviceId: String?
    
    var body: some View {
        ZStack {
 // 背景
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            if remoteControlManager.isControlling {
 // 近距镜像显示区域（Metal 纹理渲染）
                RemoteDisplayView(
                    textureFeed: remoteControlManager.textureFeed,
                    onMouseEvent: { point, eventType, button in
                        guard let did = currentDeviceId else { return }
                        let mapped: MouseEventType = mapMouseEventType(eventType)
                        let ev = RemoteMouseEvent(
                            type: mapped,
                            x: Double(point.x),
                            y: Double(point.y),
                            timestamp: Date().timeIntervalSince1970
                        )
                        Task { try? await remoteControlManager.sendMouseEvent(ev, to: did) }
                    },
                    onKeyboardEvent: { keyCode, isPressed in
                        guard let did = currentDeviceId else { return }
                        let kev = RemoteKeyboardEvent(
                            type: isPressed ? .keyDown : .keyUp,
                            keyCode: Int(keyCode),
                            timestamp: Date().timeIntervalSince1970
                        )
                        Task { try? await remoteControlManager.sendKeyboardEvent(kev, to: did) }
                    },
                    onScrollEvent: { _, _ in /* 暂不支持滚轮事件的近距远端编码 */ }
                )
                .overlay(alignment: .top) {
 // 顶部工具条：断开、返回设备列表
                    HStack(spacing: 12) {
                        Button {
                            if let did = currentDeviceId {
                                remoteControlManager.stopControlling(deviceId: did)
                                currentDeviceId = nil
                            }
                        } label: {
                            Label("断开镜像", systemImage: "xmark.circle")
                        }

                        Spacer()

                        Button {
 // 返回设备列表
                            remoteControlManager.stopControlling(deviceId: currentDeviceId ?? "")
                            currentDeviceId = nil
                        } label: {
                            Label("返回设备列表", systemImage: "chevron.left")
                        }
                        
                        Divider()
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                            Text(discoveryManager.encryptionStatus ?? "加密状态未知")
                                .font(.caption)
                                .foregroundColor(.secondary)
 // 握手详情：TLS版本与密码套件
                            if let hs = discoveryManager.tlsHandshakeDetails {
                                Text("· \(hs.protocolVersion) · \(hs.cipherSuite)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                }
 // 性能叠层：带宽/延迟/帧率
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "gauge.with.dots.needle.bottom")
                            Text(String(format: "%.1f Mbps", remoteControlManager.bandwidthMbps))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                            Text("\(Int(remoteControlManager.latencyMs)) ms")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "speedometer")
                            Text("\(remoteControlManager.estimatedFPS) FPS")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
 // 简易折线图（带宽与FPS）
                        Canvas { context, size in
                            let bw = remoteControlManager.bandwidthHistory
                            let fps = remoteControlManager.fpsHistory.map { Double($0) }
                            let maxBw = max(bw.max() ?? 1.0, 1.0)
                            let maxFps = max(fps.max() ?? 1.0, 1.0)
                            let count = max(bw.count, fps.count)
                            guard count > 1 else { return }
                            let stepX = size.width / CGFloat(count - 1)
                            var bwPath = Path()
                            var fpsPath = Path()
                            for i in 0..<count {
                                let x = CGFloat(i) * stepX
                                if i < bw.count {
                                    let y = size.height - CGFloat(bw[i] / maxBw) * size.height
                                    if i == 0 { bwPath.move(to: CGPoint(x: x, y: y)) } else { bwPath.addLine(to: CGPoint(x: x, y: y)) }
                                }
                                if i < fps.count {
                                    let y2 = size.height - CGFloat(fps[i] / maxFps) * size.height
                                    if i == 0 { fpsPath.move(to: CGPoint(x: x, y: y2)) } else { fpsPath.addLine(to: CGPoint(x: x, y: y2)) }
                                }
                            }
                            context.stroke(bwPath, with: .color(.blue.opacity(0.8)), lineWidth: 1.5)
                            context.stroke(fpsPath, with: .color(.green.opacity(0.8)), lineWidth: 1.0)
                        }
                        .frame(width: 160, height: 60)
                        .background(Color.black.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .padding(8)
                    .background(.thinMaterial)
                    .cornerRadius(8)
                    .padding(10)
                }
            } else {
                if discoveryManager.discoveredDevices.isEmpty {
 // 空状态 - 优雅的引导
                    emptyStateView
                } else {
 // 设备列表 - iPhone 镜像风格
                    deviceGridView
                }
            }
        }
        .navigationTitle("近距镜像 - 设备发现")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
 // 扫描指示器
                    if discoveryManager.isScanning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("扫描中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
 // 刷新按钮
                    Button(action: refreshDevices) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新设备列表")
                }
            }
        }
        .onAppear {
            startDiscovery()
        }
        .onDisappear {
            discoveryManager.stopScanning()
        }
        .alert("连接失败", isPresented: .constant(connectionError != nil)) {
            Button("确定") {
                connectionError = nil
            }
        } message: {
            if let error = connectionError {
                Text(error)
            }
        }
    }
    
 // MARK: - 空状态视图
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
 // 图标动画
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "wifi.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue.gradient)
            }
            
            VStack(spacing: 12) {
                Text("正在搜索附近的设备")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("确保目标设备与此 Mac 在同一网络")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
 // 扫描动画
            if discoveryManager.isScanning {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .opacity(scanningAnimation(for: index))
                    }
                }
                .padding(.top, 8)
            }
            
 // 提示卡片
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("同一 Wi-Fi")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("连接到相同的无线网络")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Divider()
                    .frame(height: 40)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("自动发现")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("无需手动配置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
 // MARK: - 设备网格视图
    
    private var deviceGridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)
            ], spacing: 16) {
                ForEach(discoveryManager.discoveredDevices) { device in
                    DeviceCardView(
                        device: device,
                        isSelected: selectedDevice?.id == device.id,
                        isConnecting: isConnecting && selectedDevice?.id == device.id,
                        onTap: {
                            connectToDevice(device)
                        }
                    )
                }
            }
            .padding(24)
        }
    }
    
 // MARK: - 扫描动画
    
    @State private var animationPhase = 0.0
    
    private func scanningAnimation(for index: Int) -> Double {
        let phase = (animationPhase + Double(index) * 0.3).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * sin(phase * .pi * 2)
    }
    
 // MARK: - 操作方法
    
    private func startDiscovery() {
        discoveryManager.startScanning()
        
 // 启动扫描动画
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            animationPhase = 1.0
        }
    }
    
    private func refreshDevices() {
        discoveryManager.stopScanning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            discoveryManager.startScanning()
        }
    }
    
    private func connectToDevice(_ device: DiscoveredDevice) {
        let targetDevice = resolveConnectableDevice(from: device)
        selectedDevice = targetDevice
        isConnecting = true
        connectionError = nil
        
        Task {
 // 符合Swift 6.2.1最佳实践：connectToDevice是async throws方法，需要try-catch
            do {
                if discoveryManager.activeConnection(for: targetDevice.id) == nil {
                    try await discoveryManager.connectToDevice(targetDevice)
                }
 // 连接成功，进入镜像模式
                await MainActor.run {
                    isConnecting = false
                }
                
 // 启动近距镜像会话
 // 说明：从优化的设备发现管理器获取已建立的 NWConnection，交由 RemoteControlManager 管理。
 // 符合Swift 6.2.1最佳实践：startControlling是async方法（非throws），不需要try-catch
                if let connection = discoveryManager.activeConnection(for: targetDevice.id) {
                    Task {
 // 使用设备ID字符串作为控制会话标识
                        await remoteControlManager.startControlling(deviceId: targetDevice.id.uuidString, connection: connection)
                        await MainActor.run { self.currentDeviceId = targetDevice.id.uuidString }
                    }
                } else {
 // 未能获取连接对象，提示错误
                    await MainActor.run {
                        self.connectionError = "连接对象未就绪，无法启动镜像会话"
                    }
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    if let discoveryError = error as? DeviceDiscoveryError,
                       case .deviceNotConnected = discoveryError {
                        connectionError = "设备当前没有可用的近距地址。请确认双方在同一局域网，且目标设备已开启近距发现后重试。"
                    } else {
                        connectionError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func resolveConnectableDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        guard device.ipv4 == nil && device.ipv6 == nil else { return device }
        guard let matchedOnline = matchedOnlineDevice(for: device) else { return device }

        if let resolved = unifiedDeviceManager.resolvedDiscoveredDevice(for: matchedOnline) {
            return merge(device, with: resolved)
        }

        guard matchedOnline.ipv4 != nil || matchedOnline.ipv6 != nil else { return device }
        return DiscoveredDevice(
            id: device.id,
            name: device.name,
            ipv4: matchedOnline.ipv4,
            ipv6: matchedOnline.ipv6,
            services: device.services.isEmpty ? matchedOnline.services : device.services,
            portMap: device.portMap.isEmpty ? matchedOnline.portMap : device.portMap,
            connectionTypes: device.connectionTypes.union(matchedOnline.connectionTypes),
            uniqueIdentifier: device.uniqueIdentifier ?? matchedOnline.uniqueIdentifier,
            signalStrength: device.signalStrength,
            source: device.source,
            isLocalDevice: device.isLocalDevice,
            deviceId: device.deviceId,
            pubKeyFP: device.pubKeyFP,
            macSet: device.macSet
        )
    }

    private func merge(_ base: DiscoveredDevice, with resolved: DiscoveredDevice) -> DiscoveredDevice {
        DiscoveredDevice(
            id: base.id,
            name: base.name,
            ipv4: base.ipv4 ?? resolved.ipv4,
            ipv6: base.ipv6 ?? resolved.ipv6,
            services: base.services.isEmpty ? resolved.services : base.services,
            portMap: base.portMap.isEmpty ? resolved.portMap : base.portMap,
            connectionTypes: base.connectionTypes.union(resolved.connectionTypes),
            uniqueIdentifier: base.uniqueIdentifier ?? resolved.uniqueIdentifier,
            signalStrength: base.signalStrength ?? resolved.signalStrength,
            source: base.source == .unknown ? resolved.source : base.source,
            isLocalDevice: base.isLocalDevice,
            deviceId: base.deviceId ?? resolved.deviceId,
            pubKeyFP: base.pubKeyFP ?? resolved.pubKeyFP,
            macSet: base.macSet.isEmpty ? resolved.macSet : base.macSet
        )
    }

    private func matchedOnlineDevice(for device: DiscoveredDevice) -> OnlineDevice? {
        let targetIdentifier = normalizedIdentifier(device.uniqueIdentifier)
        let targetName = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return unifiedDeviceManager.onlineDevices.first { online in
            guard !online.isLocalDevice else { return false }
            if let targetIdentifier,
               normalizedIdentifier(online.uniqueIdentifier) == targetIdentifier {
                return true
            }
            return !targetName.isEmpty &&
                online.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetName
        }
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("recent:") {
            return String(raw.dropFirst("recent:".count)).lowercased()
        }
        return raw.lowercased()
    }
}

// MARK: - 输入事件映射

/// 将 NSEvent.EventType 映射到近距镜像的远端鼠标事件类型
private func mapMouseEventType(_ type: NSEvent.EventType) -> MouseEventType {
    switch type {
    case .leftMouseDown: return .leftMouseDown
    case .leftMouseUp: return .leftMouseUp
    case .rightMouseDown: return .rightMouseDown
    case .rightMouseUp: return .rightMouseUp
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged: return .mouseMoved
    default: return .mouseMoved
    }
}

// MARK: - 设备卡片视图

struct DeviceCardView: View {
    let device: DiscoveredDevice
    let isSelected: Bool
    let isConnecting: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
 // 设备图标
                ZStack {
                    Circle()
                        .fill(deviceIconGradient)
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: deviceIcon)
                        .font(.system(size: 36))
                        .foregroundColor(.white)
                }
                
 // 设备信息
                VStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
 // 连接状态
                if isConnecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("连接中...")
                            .font(.caption)
                    }
                    .padding(.top, 4)
                } else {
                    Text("点击连接")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(cardBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    private var cardBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.05)
            } else {
                Color(NSColor.controlBackgroundColor)
            }
        }
    }
    
    private var deviceIcon: String {
        if device.name.lowercased().contains("mac") {
            return "macbook"
        } else if device.name.lowercased().contains("iphone") {
            return "iphone"
        } else if device.name.lowercased().contains("ipad") {
            return "ipad"
        } else if device.name.lowercased().contains("windows") || device.name.lowercased().contains("pc") {
            return "pc"
        } else {
            return "desktopcomputer"
        }
    }
    
    private var deviceIconGradient: LinearGradient {
        if device.name.lowercased().contains("mac") {
            return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else if device.name.lowercased().contains("iphone") || device.name.lowercased().contains("ipad") {
            return LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    private var statusColor: Color {
        return device.ipv4 != nil ? .green : .orange
    }
    
    private var statusText: String {
        if let ipv4 = device.ipv4 {
            return "可用 · \(ipv4)"
        } else {
            return "正在解析..."
        }
    }
}

// MARK: - 预览
