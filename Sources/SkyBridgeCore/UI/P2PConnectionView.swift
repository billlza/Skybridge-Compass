import SwiftUI
import Network
import Combine
import UniformTypeIdentifiers
import CryptoKit

/// P2P连接主界面 - 提供设备发现、连接管理和状态监控
public struct P2PConnectionView: View {
    
 // MARK: - 状态管理
    
    @StateObject private var networkManager = P2PNetworkManager.shared
    @StateObject private var securityManager = P2PSecurityManager()
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var selectedDevice: P2PDevice?
    @State private var showingConnectionDetails = false
    @State private var showingSecuritySettings = false
 // 新增：手动连接表单展示状态
    @State private var showingManualConnectSheet = false
    @State private var connectionPassword = ""
    @State private var isScanning = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingP2PEndpoints = false
 // 二维码扫描器弹窗显示状态
    @State private var showingQRCodeScanner = false
    
 // 防止频繁刷新的状态管理
    @State private var lastRefreshTime = Date()
    @State private var refreshThrottleTimer: Timer?
    
 // MARK: - 主界面
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 // 顶部状态栏
                statusHeaderView
                
 // 设备列表
                deviceListView
                
 // 底部控制栏
                bottomControlsView
            }
            .navigationTitle("SkyBridge 远程连接")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingSecuritySettings = true }) {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.blue)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingP2PEndpoints = true }) {
                        Image(systemName: "wifi")
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .sheet(isPresented: $showingConnectionDetails) {
            if let device = selectedDevice {
                ConnectionDetailsView(device: device)
            }
        }
 // 二维码扫描器弹窗，通过统一扫描组件解析结果
        .sheet(isPresented: $showingQRCodeScanner) {
            QRCodeScannerView(
                onResult: { content in
 // 解析二维码内容构造P2P设备并发起连接
                    if let device = parseP2PDevice(fromQRCode: content) {
                        networkManager.connectToDevice(device) {
                            showAlert("连接成功", "已连接到 \(device.name)")
                        } connectionFailed: { error in
                            showAlert("连接失败", error.localizedDescription)
                        }
                    } else {
                        showAlert("未识别的二维码", "二维码内容格式不正确或缺少必要信息")
                    }
 // 关闭扫描器
                    showingQRCodeScanner = false
                },
                onError: { message in
                    showAlert("扫描失败", message)
                    showingQRCodeScanner = false
                }
            )
            .frame(minWidth: 500, minHeight: 320)
        }
 // 手动连接表单（输入主机与端口）
        .sheet(isPresented: $showingManualConnectSheet) {
            ManualConnectSheet { host, port, name, type in
 // 构造最小设备信息并发起连接（公钥为空为占位）
                let device = P2PDevice(
                    id: UUID().uuidString,
                    name: name.isEmpty ? host : name,
                    type: type,
                    address: host,
                    port: UInt16(port),
                    osVersion: "unknown",
                    capabilities: [],
                    publicKey: Data(),
                    lastSeen: Date(),
                    endpoints: ["\(host):\(port)"]
                )
                networkManager.connectToDevice(device) {
                    showAlert("连接成功", "已连接到 \(device.name)")
                } connectionFailed: { error in
                    showAlert("连接失败", error.localizedDescription)
                }
            }
        }
        .sheet(isPresented: $showingSecuritySettings) {
            SecuritySettingsView(securityManager: securityManager)
        }
        .alert("连接提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            startDeviceDiscovery()
        }
        .onDisappear {
 // 视图销毁时清理定时器，防止内存泄漏
            refreshThrottleTimer?.invalidate()
            refreshThrottleTimer = nil
        }
    }
    
 // MARK: - 状态头部视图
    
    private var statusHeaderView: some View {
        VStack(spacing: 12) {
 // 网络状态指示器
            HStack {
                Circle()
                    .fill(networkStatusColor)
                    .frame(width: 12, height: 12)
                    .animation(.easeInOut(duration: 0.5), value: networkManager.networkState)
                
                Text(networkStatusText)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
 // 扫描按钮
                Button(action: toggleScanning) {
                    HStack(spacing: 6) {
                        Image(systemName: isScanning ? "stop.circle" : "magnifyingglass")
                        Text(isScanning ? "停止扫描" : "扫描设备")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
            
 // 连接统计信息
            HStack(spacing: 20) {
                StatisticView(
                    title: "发现设备",
                    value: "\(networkManager.discoveredDevices.count)",
                    icon: "antenna.radiowaves.left.and.right"
                )
                
                StatisticView(
                    title: "活跃连接",
                    value: "\(networkManager.activeConnections.count)",
                    icon: "link"
                )
                
                StatisticView(
                    title: "信任设备",
                    value: "\(securityManager.trustedDevices.count)",
                    icon: "checkmark.shield"
                )
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
    
 // MARK: - 设备列表视图
    
    private var deviceListView: some View {
        List {
 // 附近设备部分
            Section("附近设备") {
                ForEach(sortedDiscoveredDevices, id: \.deviceId) { device in
                    DeviceRowView(
                        device: device,
                        isConnected: networkManager.isConnected(to: device.deviceId),
                        isTrusted: securityManager.isTrustedDevice(device.deviceId),
                        onConnect: { connectToDevice(device) },
                        onDisconnect: { disconnectFromDevice(device) },
                        onShowDetails: { showDeviceDetails(device) }
                    )
                }
            }
            
 // 历史连接部分
            if !networkManager.connectionHistory.isEmpty {
                Section("历史连接") {
                    ForEach(networkManager.connectionHistory.prefix(5), id: \.deviceId) { device in
                        HistoryDeviceRowView(
                            device: device,
                            onReconnect: { reconnectToDevice(device) }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refreshDeviceList()
        }
    }

 /// 排序规则稳定化：为每个设备计算权重分值
 /// 权重 = 验签(2000) + 已连接(1000) + 信号强度(0~100)
 /// 其次按最近消息时间戳降序、最后按名称升序做稳定排序，避免列表频繁跳动
    private var sortedDiscoveredDevices: [P2PDevice] {
        func score(for d: P2PDevice) -> Int {
            let verifiedScore = d.isVerified ? settingsManager.sortWeightVerified : 0
            let connectedScore = networkManager.isConnected(to: d.deviceId) ? settingsManager.sortWeightConnected : 0
            let strengthScore = Int(d.signalStrength * Double(settingsManager.sortWeightSignalMultiplier))
            return verifiedScore + connectedScore + strengthScore
        }
        return networkManager.discoveredDevices.sorted { a, b in
            let sa = score(for: a)
            let sb = score(for: b)
            if sa != sb { return sa > sb }
            let ta = a.lastMessageTimestamp ?? a.lastSeen
            let tb = b.lastMessageTimestamp ?? b.lastSeen
            if ta != tb { return ta > tb }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }
    
 // MARK: - 底部控制栏
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
 // 快速连接按钮
            HStack(spacing: 16) {
                Button(action: showQRCodeScanner) {
                    VStack(spacing: 4) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                        Text("扫码连接")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Button(action: showManualConnection) {
                    VStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(.title2)
                        Text("手动连接")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Button(action: showConnectionCode) {
                    VStack(spacing: 4) {
                        Image(systemName: "qrcode")
                            .font(.title2)
                        Text("我的连接码")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Spacer()
                
 // 网络质量指示器
                NetworkQualityIndicator(quality: networkManager.networkQuality)
            }
            .padding(.horizontal)
            
 // 当前连接信息
            if let activeConnection = networkManager.activeConnections.first {
                ActiveConnectionBanner(
                    connection: activeConnection.value,
                    onDisconnect: {
 // 断开当前活跃连接，并提示用户
                        networkManager.disconnectFromDevice(activeConnection.value.device.deviceId)
                        showAlert("已断开连接", "已断开与 \(activeConnection.value.device.name) 的连接")
                    }
                )
            }
        }
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.gray.opacity(0.3)),
            alignment: .top
        )
    }
    
 // MARK: - 计算属性
    
    private var networkStatusColor: Color {
        switch networkManager.networkState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .discovering:
            return .blue
        case .idle:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var networkStatusText: String {
        switch networkManager.networkState {
        case .connected:
            return "网络已连接"
        case .connecting:
            return "正在连接..."
        case .disconnected:
            return "网络未连接"
        case .discovering:
            return "正在扫描设备..."
        case .idle:
            return "空闲状态"
        case .error:
            return "网络错误"
        }
    }
    
 // MARK: - 方法实现
    
    private func startDeviceDiscovery() {
        Task {
            await networkManager.startDiscovery()
            isScanning = true
        }
    }
    
    private func toggleScanning() {
        if isScanning {
            networkManager.stopDiscovery()
            isScanning = false
        } else {
            Task {
                await networkManager.startDiscovery()
                isScanning = true
            }
        }
    }
    
    private func connectToDevice(_ device: P2PDevice) {
        networkManager.connectToDevice(device,
                                     connectionEstablished: {
                                         showAlert("连接成功", "已成功连接到 \(device.name)")
                                     },
                                     connectionFailed: { error in
                                         showAlert("连接失败", error.localizedDescription)
                                     })
    }
    
    private func disconnectFromDevice(_ device: P2PDevice) {
        networkManager.disconnectFromDevice(device.deviceId)
        showAlert("已断开连接", "已断开与 \(device.name) 的连接")
    }
    
    private func showDeviceDetails(_ device: P2PDevice) {
        selectedDevice = device
        showingConnectionDetails = true
    }
    
    private func reconnectToDevice(_ device: P2PDevice) {
        connectToDevice(device)
    }
    
    private func refreshDeviceList() async {
 // 防止频繁刷新，最少间隔2秒
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(lastRefreshTime)
        
        if timeSinceLastRefresh < 2.0 {
            SkyBridgeLogger.ui.debugOnly("⚠️ 刷新过于频繁，跳过本次刷新")
            return
        }
        
 // 取消之前的定时器
        refreshThrottleTimer?.invalidate()
        
 // 设置新的定时器，延迟执行刷新
        refreshThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task {
                await networkManager.refreshDiscovery()
                await MainActor.run {
                    lastRefreshTime = Date()
                }
            }
        }
    }
    
    private func showQRCodeScanner() {
 // 打开二维码扫描器弹窗
        showingQRCodeScanner = true
    }
    
    private func showManualConnection() {
 // 打开手动连接表单，由用户输入连接参数后发起连接
        showingManualConnectSheet = true
    }
    
    private func showConnectionCode() {
 // 说明：连接码功能涉及令牌生成与服务端校验，后续版本将提供完整支持。
        showAlert("功能规划", "连接码功能将支持一次性令牌与有效期管理")
    }
    
    private func showAlert(_ title: String, _ message: String) {
        alertMessage = message
        showingAlert = true
    }

 // MARK: - 扫码解析
 /// 从二维码内容解析构造 P2PDevice
 /// 支持三种格式：
 /// 1) URL schema: skybridge://p2p?host=...&port=...&name=...&type=macOS
 /// 2) URL schema: skybridge://connect/eyJpZCI6ICIxLi4uIn0= （Base64 JSON，支持签名参数）
 /// - 可选 Query 参数：sig（Base64）、pk（Base64 公钥）、ts（时间戳）、fp（公钥指纹十六进制）
 /// 3) 纯 JSON：{"payload": {"id": "...", "name": "...", "address": "...", "port": 8081, "type": "macOS"}, "signatureBase64": "...", "publicKeyBase64": "...", "timestamp": 0, "publicKeyFingerprint": "hex"}
    private func parseP2PDevice(fromQRCode content: String) -> P2PDevice? {
 // 尝试处理 skybridge://connect/<base64>[?sig=..&pk=..&ts=..&fp=..]
        if content.hasPrefix("skybridge://connect/") {
 // 优先当作 URL 解析，获取 query 参数；若失败则回退到直接截取
            if let url = URL(string: content), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let pathPart = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let data = Data(base64Encoded: pathPart), let str = String(data: data, encoding: .utf8) {
 // 从 JSON 解析设备并尝试验签（若提供签名参数）
                    var device = parseP2PDevice(fromJSON: str)
                    if let d = device {
 // 读取签名相关参数
                        let sigB64 = components.queryItems?.first(where: { $0.name.lowercased() == "sig" })?.value
                        let pkB64 = components.queryItems?.first(where: { $0.name.lowercased() == "pk" })?.value
                        let tsStr = components.queryItems?.first(where: { $0.name.lowercased() == "ts" })?.value
                        let fpHex = components.queryItems?.first(where: { $0.name.lowercased() == "fp" })?.value
                        let ts = tsStr.flatMap { Double($0) }
                        if let pkB64, let sigB64 {
 // 使用统一安全管理器入口进行验签
                            let verify = securityManager.verifyQRCodeSignature(for: d, publicKeyBase64: pkB64, signatureBase64: sigB64, timestamp: ts, fingerprintHex: fpHex)
                            device = setVerification(for: d, ok: verify.ok, reason: verify.reason)
                        }
                        return device
                    }
                }
            } else {
 // 回退处理：不含 query 的简单 Base64
                let base64 = String(content.dropFirst("skybridge://connect/".count))
                if let data = Data(base64Encoded: base64), let str = String(data: data, encoding: .utf8) {
                    return parseP2PDevice(fromJSON: str)
                }
            }
        }
 // 处理 skybridge://p2p 与通用 URL
        if let url = URL(string: content), let scheme = url.scheme {
            if scheme == "skybridge" {
 // 优先读取 query items
                var host: String? = nil
                var port: Int? = nil
                var name: String? = nil
                var type: P2PDeviceType = .macOS
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    if let items = components.queryItems {
                        for item in items {
                            switch item.name.lowercased() {
                            case "host", "address":
                                host = item.value
                            case "port":
                                if let v = item.value, let p = Int(v) { port = p }
                            case "name", "device":
                                name = item.value
                            case "type":
                                if let v = item.value, let t = P2PDeviceType(rawValue: v) {
                                    type = t
                                }
                            default:
                                break
                            }
                        }
                    }
                }
 // 如果 query 未提供主机，尝试使用 host 部分
                if host == nil { host = url.host }
 // 构造设备
                if let host, let p = port ?? 8081 as Int? {
                    var device = P2PDevice(
                        id: UUID().uuidString,
                        name: (name?.isEmpty == false ? name! : host),
                        type: type,
                        address: host,
                        port: UInt16(p),
                        osVersion: "unknown",
                        capabilities: [],
                        publicKey: Data(),
                        lastSeen: Date(),
                        endpoints: ["\(host):\(p)"]
                    )
 // 若提供签名参数，尝试验签（pk/sig/ts/fp）
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        let sigB64 = components.queryItems?.first(where: { $0.name.lowercased() == "sig" })?.value
                        let pkB64 = components.queryItems?.first(where: { $0.name.lowercased() == "pk" })?.value
                        let tsStr = components.queryItems?.first(where: { $0.name.lowercased() == "ts" })?.value
                        let fpHex = components.queryItems?.first(where: { $0.name.lowercased() == "fp" })?.value
                        let ts = tsStr.flatMap { Double($0) }
                        if let pkB64, let sigB64 {
 // 使用统一安全管理器入口进行验签
                            let verify = securityManager.verifyQRCodeSignature(for: device, publicKeyBase64: pkB64, signatureBase64: sigB64, timestamp: ts, fingerprintHex: fpHex)
                            device = setVerification(for: device, ok: verify.ok, reason: verify.reason)
                        }
                    }
                    return device
                }
            }
        }
 // 处理纯 JSON
        if let device = parseP2PDevice(fromJSON: content) { return device }
        return nil
    }

 /// 尝试从简化 JSON 解析设备信息
    private func parseP2PDevice(fromJSON json: String) -> P2PDevice? {
 // 支持两种 JSON 格式
 // A) 简化设备信息：直接字段在根对象
 // B) 带签名封装：{"payload": {...设备字段...}, "signatureBase64": "...", "publicKeyBase64": "...", "timestamp": 0, "publicKeyFingerprint": "hex"}
        struct QRDevicePayload: Codable {
            let id: String?
            let name: String?
            let type: String?
            let address: String?
            let port: Int?
            let osVersion: String?
            let capabilities: [String]?
        }
        struct QRSignatureEnvelope: Codable {
            let payload: QRDevicePayload?
            let signatureBase64: String?
            let publicKeyBase64: String?
            let timestamp: Double?
            let publicKeyFingerprint: String?
        }
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
 // 优先尝试签名封装格式
        if let env = try? decoder.decode(QRSignatureEnvelope.self, from: data), let payload = env.payload {
            guard let host = payload.address, let p = payload.port ?? 8081 as Int? else { return nil }
            let t = payload.type.flatMap { P2PDeviceType(rawValue: $0) } ?? .macOS
            var device = P2PDevice(
                id: payload.id ?? UUID().uuidString,
                name: (payload.name?.isEmpty == false ? payload.name! : host),
                type: t,
                address: host,
                port: UInt16(p),
                osVersion: payload.osVersion ?? "unknown",
                capabilities: payload.capabilities ?? [],
                publicKey: Data(),
                lastSeen: Date(),
                endpoints: ["\(host):\(p)"]
            )
            if let pkB64 = env.publicKeyBase64, let sigB64 = env.signatureBase64 {
 // 使用统一安全管理器入口进行验签
                let verify = securityManager.verifyQRCodeSignature(for: device, publicKeyBase64: pkB64, signatureBase64: sigB64, timestamp: env.timestamp, fingerprintHex: env.publicKeyFingerprint)
                device = setVerification(for: device, ok: verify.ok, reason: verify.reason)
            }
            return device
        }
 // 回退到简化根对象格式
        if let payload = try? decoder.decode(QRDevicePayload.self, from: data) {
            guard let host = payload.address, let p = payload.port ?? 8081 as Int? else { return nil }
            let t = payload.type.flatMap { P2PDeviceType(rawValue: $0) } ?? .macOS
            let device = P2PDevice(
                id: payload.id ?? UUID().uuidString,
                name: (payload.name?.isEmpty == false ? payload.name! : host),
                type: t,
                address: host,
                port: UInt16(p),
                osVersion: payload.osVersion ?? "unknown",
                capabilities: payload.capabilities ?? [],
                publicKey: Data(),
                lastSeen: Date(),
                endpoints: ["\(host):\(p)"]
            )
            return device
        }
        return nil
    }

 // 已统一到 P2PSecurityManager.verifyQRCodeSignature(...)，此处不再实现本地逻辑

 /// 设置设备验签状态与失败原因（复制并返回新设备结构）
    private func setVerification(for device: P2PDevice, ok: Bool, reason: String?) -> P2PDevice {
        return P2PDevice(
            id: device.id,
            name: device.name,
            type: device.deviceType,
            address: device.address,
            port: device.port,
            osVersion: device.osVersion,
            capabilities: device.capabilities,
            publicKey: device.publicKey,
            lastSeen: device.lastSeen,
            endpoints: device.endpoints,
            lastMessageTimestamp: device.lastMessageTimestamp,
            isVerified: ok,
            verificationFailedReason: ok ? nil : (reason ?? "未知原因")
        )
    }
}

// MARK: - 统计信息视图

private struct StatisticView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.blue)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 设备行视图

private struct DeviceRowView: View {
    let device: P2PDevice
    let isConnected: Bool
    let isTrusted: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onShowDetails: () -> Void

 // 本地提示状态（用于显示验签失败原因）
    @State private var showVerificationAlert = false
    @State private var verificationMessage: String = ""
    
    var body: some View {
        HStack(spacing: 12) {
 // 设备图标
            VStack {
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceIconColor)
                
                if isTrusted {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else if !device.isVerified {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .onTapGesture {
                            if let reason = device.verificationFailedReason {
                                verificationMessage = reason
                                showVerificationAlert = true
                            }
                        }
                }
            }
            .frame(width: 40)
            
 // 设备信息
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(device.deviceType.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
 // 信号强度
                    SignalStrengthView(strength: device.signalStrength)
                    
 // 连接状态
                    Text(isConnected ? "已连接" : "可连接")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConnected ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                        .foregroundColor(isConnected ? .green : .blue)
                        .cornerRadius(4)
                    
 // 验签失败徽标
                    if !device.isVerified {
                        Text("验签失败")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                            .onTapGesture {
                                if let reason = device.verificationFailedReason {
                                    verificationMessage = reason
                                    showVerificationAlert = true
                                }
                            }
                    }
                }
            }
            
            Spacer()
            
 // 操作按钮
            VStack(spacing: 8) {
                Button(action: isConnected ? onDisconnect : onConnect) {
                    Image(systemName: isConnected ? "xmark.circle" : "play.circle")
                        .font(.title3)
                        .foregroundColor(isConnected ? .red : .green)
                }
                
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetails()
        }
        .alert("验签失败", isPresented: $showVerificationAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(verificationMessage)
        }
    }
    
    private var deviceIcon: String {
        switch device.deviceType {
        case .macOS:
            return "desktopcomputer"
        case .iOS:
            return "iphone"
        case .iPadOS:
            return "ipad"
        case .windows:
            return "pc"
        case .android:
            return "smartphone"
        case .linux:
            return "server.rack"
        }
    }
    
    private var deviceIconColor: Color {
        isConnected ? .green : .blue
    }
}

// MARK: - 历史设备行视图

private struct HistoryDeviceRowView: View {
    let device: P2PDevice
    let onReconnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                
                Text("上次连接: \(formatLastConnection(device.lastSeen))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("重连") {
                onReconnect()
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
        .padding(.vertical, 2)
    }
    
    private func formatLastConnection(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 信号强度视图

private struct SignalStrengthView: View {
    let strength: Double // 0.0 - 1.0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                Rectangle()
                    .frame(width: 3, height: CGFloat(4 + index * 2))
                    .foregroundColor(barColor(for: index))
            }
        }
    }
    
    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 4.0
        if strength >= threshold {
            return strength > 0.7 ? .green : strength > 0.4 ? .orange : .red
        } else {
            return .gray.opacity(0.3)
        }
    }
}

// MARK: - 网络质量指示器

private struct NetworkQualityIndicator: View {
    let quality: P2PConnectionQuality
    
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(qualityColor)
                .frame(width: 8, height: 8)
            
            Text(qualityText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var qualityColor: Color {
        switch quality.qualityLevel {
        case .excellent:
            return .green
        case .good:
            return .blue
        case .fair:
            return .orange
        case .poor:
            return .red
        }
    }
    
    private var qualityText: String {
        switch quality.qualityLevel {
        case .excellent:
            return "优秀"
        case .good:
            return "良好"
        case .fair:
            return "一般"
        case .poor:
            return "较差"
        }
    }
}

// MARK: - 活跃连接横幅

private struct ActiveConnectionBanner: View {
    let connection: P2PConnection
    let onDisconnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("已连接到 \(connection.device.name)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("延迟: \(Int(connection.latency * 1000))ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("断开") {
 // 调用外部传入的断开回调，确保断开逻辑由上层统一管理
                onDisconnect()
            }
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

// MARK: - 手动连接表单视图

private struct ManualConnectSheet: View {
 /// 连接回调：host、port、name、type
    let onConnect: (_ host: String, _ port: Int, _ name: String, _ type: P2PDeviceType) -> Void
    
 // 表单输入状态
    @State private var host: String = ""
    @State private var port: String = "8081" // 默认TCP端口
    @State private var name: String = ""
    @State private var type: P2PDeviceType = .macOS
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("连接信息") {
                    TextField("主机名或IP地址", text: $host)
                    TextField("端口", text: $port)
                        .onReceive(port.publisher.collect()) { _ in
 // 端口输入仅允许数字
                            port = port.filter { $0.isNumber }
                        }
                    Picker("设备类型", selection: $type) {
                        ForEach(P2PDeviceType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                }
                
                Section("标识信息（可选）") {
                    TextField("设备名称（默认使用主机名）", text: $name)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("手动连接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        guard let p = Int(port), !host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onConnect(host, p, name, type)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
                }
            }
        }
        .frame(width: 420, height: 300)
    }
}

// MARK: - 预览

#if DEBUG
struct P2PConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        P2PConnectionView()
    }
}
#endif