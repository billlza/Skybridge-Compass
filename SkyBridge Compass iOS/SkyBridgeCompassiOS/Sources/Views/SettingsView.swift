import SwiftUI

/// 设置视图 - 应用配置和偏好设置
@available(iOS 17.0, *)
struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var localizationManager: LocalizationManager
    
    @StateObject private var settingsManager = SettingsManager.instance
    @State private var showLogoutConfirmation = false
    
    var body: some View {
        NavigationStack {
            List {
                // 用户信息
                userProfileSection
                
                // 连接设置
                connectionSettingsSection
                
                // 安全设置
                securitySettingsSection
                
                // 外观设置
                appearanceSettingsSection
                
                // 高级设置
                advancedSettingsSection
                
                // 关于
                aboutSection
                
                // 退出登录
                logoutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                "确定要退出登录吗？",
                isPresented: $showLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button("退出登录", role: .destructive) {
                    logout()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
    
    // MARK: - User Profile Section
    
    private var userProfileSection: some View {
        Section {
            HStack(spacing: 16) {
                // 用户头像
                ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    if let url = authManager.currentUser?.avatarURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: "person.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                        }
                    } else {
                        Image(systemName: "person.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                
                // 用户信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(authManager.currentUser?.displayName ?? "用户")
                        .font(.headline)
                    
                    Text(authManager.currentUser?.email ?? "未登录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let nebulaId = authManager.currentUser?.nebulaId, !nebulaId.isEmpty {
                        Text("NebulaID: \(nebulaId)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    if let deviceID = UIDevice.current.identifierForVendor?.uuidString.prefix(8) {
                        Text("设备 ID: \(deviceID)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if authManager.isAuthenticated && !authManager.isGuestMode {
                    Button("刷新") {
                        Task { await authManager.refreshProfile() }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Connection Settings
    
    private var connectionSettingsSection: some View {
        Section("连接设置") {
            NavigationLink(destination: DiscoverySettingsView()) {
                Label("设备发现", systemImage: "wifi.circle")
            }
            
            Toggle(isOn: $settingsManager.autoReconnect) {
                Label("自动重连", systemImage: "arrow.clockwise")
            }
            
            Toggle(isOn: $settingsManager.allowBackgroundConnection) {
                Label("后台连接", systemImage: "moon.fill")
            }
        }
    }
    
    // MARK: - Security Settings
    
    private var securitySettingsSection: some View {
        Section("安全与隐私") {
            NavigationLink(destination: PQCSecuritySettingsView()) {
                HStack {
                    Label("后量子加密", systemImage: "lock.shield.fill")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            
            NavigationLink(destination: TrustedDevicesView()) {
                Label("受信任的设备", systemImage: "checkmark.shield")
            }
            
            Toggle(isOn: $settingsManager.requireBiometricAuth) {
                Label("生物识别认证", systemImage: "faceid")
            }
            
            Toggle(isOn: $settingsManager.endToEndEncryption) {
                Label("端到端加密", systemImage: "lock.fill")
            }
        }
    }
    
    // MARK: - Appearance Settings
    
    private var appearanceSettingsSection: some View {
        Section("外观") {
            Picker("主题", selection: $themeConfiguration.isDarkMode) {
                Text("浅色").tag(false)
                Text("深色").tag(true)
            }
            
            Picker("语言", selection: $localizationManager.currentLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            
            ColorPicker("强调色", selection: $themeConfiguration.accentColor)
        }
    }
    
    // MARK: - Advanced Settings
    
    private var advancedSettingsSection: some View {
        Section("高级") {
            NavigationLink(destination: PerformanceSettingsView()) {
                Label("性能优化", systemImage: "speedometer")
            }
            
            NavigationLink(destination: ClipboardSettingsView()) {
                Label("剪贴板同步", systemImage: "doc.on.clipboard")
            }
            
            NavigationLink(destination: CloudSyncSettingsView()) {
                Label("iCloud 同步", systemImage: "icloud.fill")
            }

            NavigationLink(destination: SupabaseSettingsView()) {
                Label("Supabase 配置", systemImage: "server.rack")
            }
            
            NavigationLink(destination: LogsView()) {
                Label("日志查看", systemImage: "doc.text.magnifyingglass")
            }

            Toggle(isOn: $settingsManager.enableRealTimeWeather) {
                Label("实时天气（API）", systemImage: "cloud.sun")
            }

            Toggle(isOn: $settingsManager.enableExperimentalFeatures) {
                Label("实验功能（Beta）", systemImage: "testtube.2")
            }
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("构建号")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundColor(.secondary)
            }
            
            NavigationLink(destination: LicensesView()) {
                Text("开源许可")
            }
            
            NavigationLink(destination: PrivacyPolicyView()) {
                Text("隐私政策")
            }
            
            Link("GitHub 仓库", destination: URL(string: "https://github.com/billlza/Skybridge-Compass")!)
        }
    }
    
    // MARK: - Logout Section
    
    private var logoutSection: some View {
        Section {
            Button(role: .destructive, action: { showLogoutConfirmation = true }) {
                HStack {
                    Spacer()
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func logout() {
        Task {
            await authManager.signOut()
        }
    }
}

// MARK: - PQC Security Settings View

@available(iOS 17.0, *)
struct PQCSecuritySettingsView: View {
    @StateObject private var pqcManager = PQCCryptoManager.instance
    
    var body: some View {
        List {
            Section("加密算法") {
                HStack {
                    Text("密钥交换")
                    Spacer()
                    Text("ML-KEM-768")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("数字签名")
                    Spacer()
                    Text("ML-DSA-65")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("混合加密")
                    Spacer()
                    Text("X-Wing")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Section("密钥状态") {
                HStack {
                    Label("本地密钥对", systemImage: "key.fill")
                    Spacer()
                    if pqcManager.hasKeyPair {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("生成") {
                            generateKeyPair()
                        }
                    }
                }
                
                if let keyGenDate = pqcManager.keyGenerationDate {
                    HStack {
                        Text("生成时间")
                        Spacer()
                        Text(keyGenDate.formatted())
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section("安全选项") {
                Toggle("强制 PQC 握手", isOn: $pqcManager.enforcePQCHandshake)
                
                Toggle("允许经典降级（兼容旧设备）", isOn: $pqcManager.allowClassicFallbackForCompatibility)
                    .disabled(pqcManager.enforcePQCHandshake)
                    .opacity(pqcManager.enforcePQCHandshake ? 0.5 : 1.0)
                
                Toggle("密钥自动轮换", isOn: $pqcManager.autoKeyRotation)
                
                if pqcManager.autoKeyRotation {
                    Picker("轮换周期", selection: $pqcManager.keyRotationDays) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                    }
                }
            }
            
            Section {
                Button(role: .destructive, action: regenerateKeys) {
                    Label("重新生成密钥", systemImage: "arrow.clockwise")
                }
            }

            Section("论文 / 学术验证") {
                NavigationLink(destination: RealNetworkE2EBenchView()) {
                    Label("RealNet E2E Micro-Study", systemImage: "antenna.radiowaves.left.and.right")
                }
                Text("在 iPhone/iPad 上作为 client，连接到 Mac 上的测试 server，对比 classic(827B) 与 PQC(12,163B) 的端到端时延与失败类型，并导出 CSV 到 Artifacts 管线。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("后量子加密")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func generateKeyPair() {
        Task {
            try? await pqcManager.generateKeyPair()
        }
    }
    
    private func regenerateKeys() {
        Task {
            try? await pqcManager.regenerateKeyPair()
        }
    }
}

// MARK: - Placeholder Views

struct DiscoverySettingsView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @StateObject private var settings = SettingsManager.instance

    var body: some View {
        Form {
            Section("发现开关") {
                Toggle(isOn: $settings.discoveryEnabled) {
                    Text("启用设备发现")
                }
                .onChange(of: settings.discoveryEnabled) { _, _ in
                    applyDiscovery()
                }

                Button("刷新设备列表") {
                    Task { await discoveryManager.refresh() }
                }
            }

            Section {
                Picker("模式", selection: $settings.discoveryModePreset) {
                    Text("SkyBridge（省电）").tag(0)
                    Text("扩展").tag(1)
                    Text("完整").tag(2)
                    Text("自定义").tag(3)
                }
                .onChange(of: settings.discoveryModePreset) { _, _ in
                    applyDiscovery()
                }

                if settings.discoveryModePreset == 3 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("全选") {
                                settings.discoveryCustomServiceTypes = DiscoveryServiceType.allCases.map { $0.rawValue }
                                applyDiscovery()
                            }
                            Spacer()
                            Button("仅 SkyBridge") {
                                settings.discoveryCustomServiceTypes = [DiscoveryServiceType.skybridge.rawValue, DiscoveryServiceType.skybridgeQUIC.rawValue]
                                applyDiscovery()
                            }
                            Spacer()
                            Button("清空") {
                                settings.discoveryCustomServiceTypes = []
                                applyDiscovery()
                            }
                        }
                        .font(.caption)

                        ForEach(DiscoveryServiceType.allCases, id: \.rawValue) { type in
                            Toggle(isOn: Binding(
                                get: { settings.discoveryCustomServiceTypes.contains(type.rawValue) },
                                set: { enabled in
                                    if enabled {
                                        if !settings.discoveryCustomServiceTypes.contains(type.rawValue) {
                                            settings.discoveryCustomServiceTypes.append(type.rawValue)
                                        }
                                    } else {
                                        settings.discoveryCustomServiceTypes.removeAll { $0 == type.rawValue }
                                    }
                                    applyDiscovery()
                                }
                            )) {
                                Text(type.displayName)
                            }
                        }
                    }
                }
            } header: {
                Text("发现模式")
            } footer: {
                Text("完整模式会浏览更多 Bonjour 服务，可能更耗电。自定义模式可按需选择服务类型。")
            }
        }
            .navigationTitle("设备发现")
    }

    private func applyDiscovery() {
        // 周期刷新（省电策略）
        discoveryManager.setPeriodicRefreshInterval(seconds: settings.discoveryRefreshIntervalSeconds)

        Task {
            if settings.discoveryEnabled {
                let mode: DiscoveryMode
                switch settings.discoveryModePreset {
                case 1: mode = .extended
                case 2: mode = .full
                case 3:
                    let types = settings.discoveryCustomServiceTypes.compactMap { DiscoveryServiceType(rawValue: $0) }
                    mode = .custom(types.isEmpty ? [.skybridge, .skybridgeQUIC] : types)
                default: mode = .skybridgeOnly
                }
                try? await discoveryManager.startDiscovery(mode: mode)
            } else {
                discoveryManager.stopDiscovery()
            }
        }
    }
}

struct TrustedDevicesView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @StateObject private var store = TrustedDeviceStore.shared

    var body: some View {
        List {
            if store.trustedDevices.isEmpty {
                Section {
                    Text("暂无受信任设备。你可以在设备验证成功后自动加入，或在下面从已发现设备手动加入。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Section("受信任设备") {
                    ForEach(store.trustedDevices) { dev in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dev.name).font(.headline)
                            HStack(spacing: 8) {
                                Text(dev.platform.displayName)
                                if let ip = dev.ipAddress { Text(ip) }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            Text("ID: \(dev.id)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { idxSet in
                        for idx in idxSet {
                            let id = store.trustedDevices[idx].id
                            store.untrust(deviceId: id)
                        }
                    }
                }
            }

            Section("从已发现设备添加") {
                let candidates = discoveryManager.discoveredDevices.filter { !store.isTrusted(deviceId: $0.id) }
                if candidates.isEmpty {
                    Text("当前没有可添加的设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates) { dev in
                        Button {
                            store.trust(dev)
                        } label: {
                            HStack {
                                Text(dev.name)
                                Spacer()
                                Text(dev.platform.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            if !store.trustedDevices.isEmpty {
                Section {
                    Button(role: .destructive) {
                        store.clearAll()
                    } label: {
                        Text("清空受信任设备")
                    }
                }
            }
        }
            .navigationTitle("受信任的设备")
    }
}

struct PerformanceSettingsView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var settings = SettingsManager.instance
    @StateObject private var clipboard = ClipboardManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("允许后台连接（耗电更高）", isOn: $settings.allowBackgroundConnection)
                    .onChange(of: settings.allowBackgroundConnection) { _, enabled in
                        if enabled {
                            Task { try? await connectionManager.startListening() }
                        }
                    }
                Toggle("自动重连", isOn: $settings.autoReconnect)
            } header: {
                Text("后台策略")
            } footer: {
                Text("关闭后台连接时，App 进入后台会停止发现与监听，以降低耗电。")
            }

            Section {
                Picker("刷新周期", selection: $settings.discoveryRefreshIntervalSeconds) {
                    Text("持续发现（更耗电）").tag(0.0)
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("120 秒").tag(120.0)
                }
                .onChange(of: settings.discoveryRefreshIntervalSeconds) { _, newValue in
                    discoveryManager.setPeriodicRefreshInterval(seconds: newValue)
                }
            } header: {
                Text("发现耗电策略（扫描周期）")
            } footer: {
                Text("设置为非 0 时会周期性 refresh（stop/start 浏览器），通常更省电，但发现更新会“间歇性”。")
            }

            Section {
                Stepper(value: $settings.maxConcurrentConnections, in: 1...8) {
                    HStack {
                        Text("最大连接并发")
                        Spacer()
                        Text("\(settings.maxConcurrentConnections)")
                            .foregroundColor(.secondary)
                    }
                }

                Picker("剪贴板最大内容大小", selection: $settings.clipboardMaxContentSize) {
                    Text("256 KB").tag(256 * 1024)
                    Text("1 MB").tag(1 * 1024 * 1024)
                    Text("5 MB").tag(5 * 1024 * 1024)
                    Text("10 MB").tag(10 * 1024 * 1024)
                }
                .onChange(of: settings.clipboardMaxContentSize) { _, v in
                    clipboard.maxContentSizeBytes = v
                }

                Picker("剪贴板最小发送间隔", selection: $settings.clipboardMinSendIntervalSeconds) {
                    Text("0.2s").tag(0.2)
                    Text("0.5s").tag(0.5)
                    Text("0.8s").tag(0.8)
                    Text("1.5s").tag(1.5)
                }
                .onChange(of: settings.clipboardMinSendIntervalSeconds) { _, v in
                    clipboard.minSendIntervalSeconds = v
                }
            } header: {
                Text("并发数 / 限速")
            } footer: {
                Text("限速优先体现在剪贴板：最大大小 + 最小发送间隔。文件传输的带宽限速可以在下一步接入传输层。")
            }

            Section {
                Stepper(value: $settings.fileTransferMaxConcurrentTransfers, in: 1...6) {
                    HStack {
                        Text("文件传输并发")
                        Spacer()
                        Text("\(settings.fileTransferMaxConcurrentTransfers)")
                            .foregroundColor(.secondary)
                    }
                }

                Picker("上传限速", selection: $settings.fileTransferUploadLimitKBps) {
                    Text("不限速").tag(0)
                    Text("256 KB/s").tag(256)
                    Text("512 KB/s").tag(512)
                    Text("1 MB/s").tag(1024)
                    Text("2 MB/s").tag(2048)
                    Text("5 MB/s").tag(5120)
                }

                Picker("下载限速", selection: $settings.fileTransferDownloadLimitKBps) {
                    Text("不限速").tag(0)
                    Text("256 KB/s").tag(256)
                    Text("512 KB/s").tag(512)
                    Text("1 MB/s").tag(1024)
                    Text("2 MB/s").tag(2048)
                    Text("5 MB/s").tag(5120)
                }
            } header: {
                Text("文件传输")
            } footer: {
                Text("限速为粗粒度节流（KB/s）。上传通过分片发送+sleep；下载通过消费端节流减少处理速度。")
            }
        }
            .navigationTitle("性能优化")
    }
}

struct ClipboardSettingsView: View {
    @StateObject private var clipboard = ClipboardManager.shared
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var settings = SettingsManager.instance

    @State private var showCopied = false
    @State private var showClearHistoryAlert = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.clipboardSyncEnabled },
                    set: { enabled in
                        settings.clipboardSyncEnabled = enabled
                        if enabled { clipboard.enable() } else { clipboard.disable() }
                    }
                )) {
                    Text("启用剪贴板同步")
                }

                Toggle("同步图片", isOn: Binding(
                    get: { settings.clipboardSyncImages },
                    set: { v in
                        settings.clipboardSyncImages = v
                        clipboard.syncImages = v
                    }
                ))
                .disabled(!settings.clipboardSyncEnabled)

                Toggle("同步 URL", isOn: Binding(
                    get: { settings.clipboardSyncFileURLs },
                    set: { v in
                        settings.clipboardSyncFileURLs = v
                        clipboard.syncFileURLs = v
                    }
                ))
                .disabled(!settings.clipboardSyncEnabled)

                Picker("最大内容大小", selection: Binding(
                    get: { settings.clipboardMaxContentSize },
                    set: { v in
                        settings.clipboardMaxContentSize = v
                        clipboard.maxContentSizeBytes = v
                    }
                )) {
                    Text("256 KB").tag(256 * 1024)
                    Text("1 MB").tag(1 * 1024 * 1024)
                    Text("5 MB").tag(5 * 1024 * 1024)
                    Text("10 MB").tag(10 * 1024 * 1024)
                }
                .disabled(!settings.clipboardSyncEnabled)

                HStack {
                    Text("状态")
                    Spacer()
                    Text(clipboard.syncStatus.displayName)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("已连接设备")
                    Spacer()
                    Text("\(connectionManager.activeConnections.count)")
                        .foregroundColor(.secondary)
                }

                if let last = clipboard.lastSyncTime {
                    HStack {
                        Text("上次同步")
                        Spacer()
                        Text(last.formatted(date: .abbreviated, time: .standard))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Label("同步状态", systemImage: "doc.on.clipboard")
            } footer: {
                Text("已支持 text / image / url，并提供历史记录与按设备状态面板（iOS 侧最小对齐 macOS）。")
            }

            Section("按设备状态") {
                if connectionManager.activeConnections.isEmpty {
                    Text("暂无已连接设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(connectionManager.activeConnections) { conn in
                        let id = conn.device.id
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conn.device.name)
                            HStack(spacing: 8) {
                                Text(id).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                if let last = clipboard.deviceLastSync[id] {
                                    Text("上次同步 \(last, style: .relative)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let mime = clipboard.deviceLastMimeType[id] {
                                    Text(mime)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("当前剪贴板") {
                if let (data, mime) = clipboard.getCurrentClipboardContent() {
                    Text("MIME: \(mime)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if mime.hasPrefix("text/"), let text = String(data: data, encoding: .utf8) {
                        Text(text)
                            .lineLimit(6)
                            .textSelection(.enabled)

                        Button(showCopied ? "已复制" : "复制文本") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = text
                            #endif
                            showCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                showCopied = false
                            }
                        }
                    } else {
                        Text("非文本内容（暂不展示预览）")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("暂无可读取内容")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button("立即同步到远端") {
                    clipboard.syncToRemote()
                }
                .disabled(!clipboard.isEnabled)

                if !clipboard.history.isEmpty {
                    Button(role: .destructive) {
                        showClearHistoryAlert = true
                    } label: {
                        Text("清空历史记录")
                    }
                }
            }

            if !clipboard.history.isEmpty {
                Section("最近历史（\(clipboard.history.count)）") {
                    ForEach(clipboard.history.reversed().prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.direction == .outgoing ? "↑" : "↓")
                                    .foregroundColor(entry.direction == .outgoing ? .blue : .green)
                                Text(entry.mimeType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.sizeBytes), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(entry.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let preview = entry.textPreview, !preview.isEmpty {
                                Text(preview)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            if let deviceId = entry.deviceId {
                                Text("设备: \(deviceId)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
            .navigationTitle("剪贴板同步")
        .alert("清空历史记录", isPresented: $showClearHistoryAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clipboard.clearHistory()
            }
        } message: {
            Text("确定要清空所有剪贴板同步历史记录吗？")
        }
    }
}

struct CloudSyncSettingsView: View {
    @StateObject private var settings = SettingsManager.instance

    var body: some View {
        Form {
            Section {
                Toggle("启用 CloudKit 同步", isOn: $settings.enableCloudKitSync)
            } footer: {
                Text("未在 Xcode Signing 中开启 iCloud/CloudKit 能力时，建议保持关闭。")
            }
        }
        .navigationTitle("iCloud 同步")
    }
}

struct SupabaseSettingsView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var supabaseURL: String = ""
    @State private var anonKey: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isTesting = false
    @State private var lastTestStatus: String?

    var body: some View {
        List {
            if let status = lastTestStatus {
                Section("状态") {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                TextField("SUPABASE_URL", text: $supabaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("SUPABASE_ANON_KEY", text: $anonKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("项目配置")
            } footer: {
                Text("配置会存入 Keychain。安全起见，iOS 客户端不支持 service-role key（仅服务端可用）。")
            }

            Section {
                Button("保存并生效") {
                    save()
                }
                .disabled(supabaseURL.isEmpty || anonKey.isEmpty)

                Button(isTesting ? "测试中..." : "测试连通性") {
                    Task { await testConnection() }
                }
                .disabled(isTesting || supabaseURL.isEmpty || anonKey.isEmpty)

                if authManager.isAuthenticated && !authManager.isGuestMode {
                    Button("刷新账号资料（NebulaID/头像）") {
                        Task { await authManager.refreshProfile() }
                    }
                }
            }
        }
        .navigationTitle("Supabase 配置")
        .task { load() }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func load() {
        if let cfg = try? KeychainManager.shared.retrieveSupabaseConfig() {
            supabaseURL = cfg.url
            anonKey = cfg.anonKey
        }
    }

    private func save() {
        do {
            try KeychainManager.shared.storeSupabaseConfig(url: supabaseURL, anonKey: anonKey)

            guard let url = URL(string: supabaseURL) else {
                alertMessage = "SUPABASE_URL 无效"
                showAlert = true
                return
            }
            SupabaseService.shared.updateConfiguration(
                .init(url: url, anonKey: anonKey)
            )

            alertMessage = "已保存到 Keychain，并已更新运行时配置。"
            showAlert = true
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            try await SupabaseService.shared.testConnection()
            lastTestStatus = "✅ Supabase 连接正常（auth/v1/health）"
        } catch {
            lastTestStatus = "❌ Supabase 连接失败：\(error.localizedDescription)"
        }
    }
}

struct LogsView: View {
    @StateObject private var store = LogStore.shared
    @State private var query: String = ""
    @State private var minLevel: LogLevel = .debug
    @State private var isSharing = false

    var body: some View {
        List {
            Section {
                TextField("搜索（message/category）", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("最小级别", selection: $minLevel) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warning").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
            } header: {
                Text("过滤")
            }

            Section {
                let text = store.exportText(minLevel: minLevel, search: query)
                ShareLink(item: text) {
                    Label("导出日志（Share）", systemImage: "square.and.arrow.up")
                }

                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = text
                    #endif
                } label: {
                    Label("复制日志", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    store.clear()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            } header: {
                Text("操作")
            }

            Section("日志（最近 \(store.entries.count) 条）") {
                ForEach(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(color(for: entry.level))
                                .frame(width: 62, alignment: .leading)

                            Text(entry.category)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(entry.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
            .navigationTitle("日志")
    }

    private var filteredEntries: [LogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.entries
            .filter { $0.level.rank >= minLevel.rank }
            .filter { q.isEmpty ? true : ("\($0.category) \($0.message)".lowercased().contains(q)) }
            .reversed()
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct LicensesView: View {
    var body: some View {
        Text("开源许可")
            .navigationTitle("开源许可")
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        Text("隐私政策")
            .navigationTitle("隐私政策")
    }
}

// MARK: - Preview
#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SettingsView()
                .environmentObject(AuthenticationManager.instance)
                .environmentObject(ThemeConfiguration.instance)
                .environmentObject(LocalizationManager.instance)
            NavigationStack {
                PQCSecuritySettingsView()
            }
        }
    }
}
#endif
