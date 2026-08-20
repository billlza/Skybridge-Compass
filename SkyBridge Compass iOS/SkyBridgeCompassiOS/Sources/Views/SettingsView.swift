import SwiftUI

/// 设置视图 - 应用配置和偏好设置
@available(iOS 17.0, *)
struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var localizationManager: LocalizationManager
    
    @StateObject private var settingsManager = SettingsManager.instance
    @StateObject private var pqcManager = PQCCryptoManager.instance
    @State private var showLogoutConfirmation = false
    @State private var showLogoutError = false
    @State private var logoutErrorMessage = ""

    private func t(_ key: String) -> String {
        localizationManager.localized(key)
    }
    
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
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
            .navigationTitle(localizationManager.localized("settings.title"))
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                t("settings.logout.confirm"),
                isPresented: $showLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button(t("settings.logout"), role: .destructive) {
                    logout()
                }
                Button(t("common.cancel"), role: .cancel) {}
            }
            .alert("退出登录失败", isPresented: $showLogoutError) {
                Button(t("common.ok"), role: .cancel) {}
            } message: {
                Text(logoutErrorMessage)
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
                    Text(authManager.currentUser?.displayName ?? t("settings.user.default_name"))
                        .font(.headline)
                    
                    Text(authManager.currentUser?.email ?? t("settings.user.not_logged_in"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let nebulaId = authManager.currentUser?.nebulaId, !nebulaId.isEmpty {
                        Text("\(RuntimeLocalization.string("Nebula 标识")): \(nebulaId)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    if let deviceID = UIDevice.current.identifierForVendor?.uuidString.prefix(8) {
                        Text("\(t("settings.user.device_id")): \(deviceID)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if authManager.isAuthenticated && !authManager.isGuestMode {
                    Button(t("common.refresh")) {
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
        Section(t("settings.section.connection")) {
            NavigationLink(destination: DiscoverySettingsView()) {
                Label(t("settings.discovery"), systemImage: "wifi.circle")
            }
            
            Toggle(isOn: $settingsManager.autoReconnect) {
                Label(t("settings.auto_reconnect"), systemImage: "arrow.clockwise")
            }
            
            Toggle(isOn: $settingsManager.allowBackgroundConnection) {
                Label(t("settings.background_connection"), systemImage: "moon.fill")
            }
        }
    }
    
    // MARK: - Security Settings
    
    private var securitySettingsSection: some View {
        Section(t("settings.section.security")) {
            NavigationLink(destination: PQCSecuritySettingsView()) {
                let pqcPolicyStatus = Self.pqcPolicyStatusPresentation(
                    enforcePQCHandshake: pqcManager.enforcePQCHandshake,
                    currentTier: pqcManager.currentTier,
                    currentSuite: pqcManager.currentSuite,
                    hasKeyPair: pqcManager.hasKeyPair
                )
                HStack {
                    Label(t("settings.pqc"), systemImage: "lock.shield.fill")
                    Spacer()
                    Text(pqcPolicyStatus.label)
                        .font(.caption)
                        .foregroundColor(Self.pqcPolicyStatusColor(for: pqcPolicyStatus.tone))
                }
            }
            
            NavigationLink(destination: TrustedDevicesView()) {
                Label(t("settings.trusted_devices"), systemImage: "checkmark.shield")
            }
            
            LabeledContent {
                Text("未启用")
                    .foregroundColor(.secondary)
            } label: {
                Label(t("settings.biometric"), systemImage: "faceid")
            }
            
            LabeledContent {
                let pqcPolicyStatus = Self.pqcPolicyStatusPresentation(
                    enforcePQCHandshake: pqcManager.enforcePQCHandshake,
                    currentTier: pqcManager.currentTier,
                    currentSuite: pqcManager.currentSuite,
                    hasKeyPair: pqcManager.hasKeyPair
                )
                Text(pqcPolicyStatus.detail)
                    .foregroundColor(.secondary)
            } label: {
                Label(t("settings.e2ee"), systemImage: "lock.fill")
            }
        }
    }
    
    // MARK: - Appearance Settings
    
    private var appearanceSettingsSection: some View {
        Section(t("settings.section.appearance")) {
            Picker(t("settings.theme"), selection: $themeConfiguration.isDarkMode) {
                Text(t("settings.theme.light")).tag(false)
                Text(t("settings.theme.dark")).tag(true)
            }
            
            Picker(localizationManager.localized("settings.language"), selection: $localizationManager.currentLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(localizationManager.displayName(for: language)).tag(language)
                }
            }
            
            ColorPicker(t("settings.accent_color"), selection: $themeConfiguration.accentColor)
        }
    }
    
    // MARK: - Advanced Settings
    
    private var advancedSettingsSection: some View {
        Section(t("settings.section.advanced")) {
            NavigationLink(destination: PerformanceSettingsView()) {
                Label(t("settings.performance"), systemImage: "speedometer")
            }
            
            NavigationLink(destination: ClipboardSettingsView()) {
                Label(t("settings.clipboard_sync"), systemImage: "doc.on.clipboard")
            }
            
            NavigationLink(destination: CloudSyncSettingsView()) {
                Label(t("settings.icloud_sync"), systemImage: "icloud.fill")
            }

            NavigationLink(destination: SupabaseSettingsView()) {
                Label(t("settings.supabase"), systemImage: "server.rack")
            }
            
            NavigationLink(destination: LogsView()) {
                Label(t("settings.logs"), systemImage: "doc.text.magnifyingglass")
            }

            Toggle(isOn: $settingsManager.enableRealTimeWeather) {
                Label(localizationManager.localized("settings.realtime_weather_api"), systemImage: "cloud.sun")
            }
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        Section(t("settings.section.about")) {
            HStack {
                Text(t("settings.version"))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text(t("settings.build"))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundColor(.secondary)
            }
            
            NavigationLink(destination: LicensesView()) {
                Text(t("settings.opensource"))
            }
            
            NavigationLink(destination: PrivacyPolicyView()) {
                Text(t("settings.privacy"))
            }
            
            if let repositoryURL = URL(string: "https://github.com/billlza/Skybridge-Compass") {
                Link(t("settings.github"), destination: repositoryURL)
            }
        }
    }
    
    // MARK: - Logout Section
    
    private var logoutSection: some View {
        Section {
            Button(role: .destructive, action: { showLogoutConfirmation = true }) {
                HStack {
                    Spacer()
                    Label(t("settings.logout"), systemImage: "rectangle.portrait.and.arrow.right")
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func logout() {
        Task {
            do {
                try await authManager.signOut()
            } catch {
                logoutErrorMessage = error.localizedDescription
                showLogoutError = true
            }
        }
    }

    internal enum PQCPolicyStatusTone: String, Equatable {
        case ready
        case pending
        case unavailable
        case classic
    }

    internal struct PQCPolicyStatusPresentation: Equatable {
        let label: String
        let detail: String
        let tone: PQCPolicyStatusTone
    }

    internal static func pqcPolicyStatusPresentation(
        enforcePQCHandshake: Bool,
        currentTier: CryptoTier,
        currentSuite: CryptoSuite,
        hasKeyPair: Bool
    ) -> PQCPolicyStatusPresentation {
        guard enforcePQCHandshake else {
            return PQCPolicyStatusPresentation(
                label: "Classic",
                detail: "未强制",
                tone: .classic
            )
        }

        guard currentTier == .qperiaptPQC
                || currentTier == .nativePQC
                || currentTier == .liboqsPQC,
              currentSuite.isPQCGroup
        else {
            return PQCPolicyStatusPresentation(
                label: "PQC 不可用",
                detail: "严格策略请求中，Provider 不可用",
                tone: .unavailable
            )
        }

        guard hasKeyPair else {
            return PQCPolicyStatusPresentation(
                label: "待初始化",
                detail: "严格 PQC 已请求，待生成本地密钥",
                tone: .pending
            )
        }

        return PQCPolicyStatusPresentation(
            label: "PQC 就绪",
            detail: "严格 PQC 已请求，Provider 与本地密钥就绪，等待会话协商证明",
            tone: .ready
        )
    }

    internal static func pqcPolicyStatusColor(for tone: PQCPolicyStatusTone) -> Color {
        switch tone {
        case .ready:
            return .green
        case .pending:
            return .orange
        case .unavailable:
            return .red
        case .classic:
            return .orange
        }
    }
}

// MARK: - PQC Security Settings View

@available(iOS 17.0, *)
struct PQCSecuritySettingsView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @StateObject private var pqcManager = PQCCryptoManager.instance
    @State private var errorMessage: String?
    @State private var requestedProviderPreference: PQCProviderPreference = .mlkem
    @State private var isApplyingProviderPreference = false
    @State private var requestedProtocolSigningAlgorithm =
        ProtocolSigningIdentityPolicy.requestedPQCAlgorithm()
    @State private var requestedSecureEnclave =
        ProtocolSigningIdentityPolicy.requestedProtection() == .secureEnclaveRequired
    @State private var activeProtocolSigningAlgorithm =
        ProtocolSigningIdentityPolicy.requestedPQCAlgorithm()
    @State private var activeProtocolSigningProtection =
        ProtocolSigningIdentityPolicy.requestedProtection()
    @State private var protocolIdentityRuntimeIsActive = false
    @State private var protocolIdentityRequiresExplicitConfirmation =
        ProtocolSigningIdentityPolicy.configurationResolution()
            .needsExplicitConfirmation
    @State private var isApplyingProtocolIdentity = false
    
    var body: some View {
        List {
            Section("加密算法") {
                let pqcPolicyStatus = SettingsView.pqcPolicyStatusPresentation(
                    enforcePQCHandshake: pqcManager.enforcePQCHandshake,
                    currentTier: pqcManager.currentTier,
                    currentSuite: pqcManager.currentSuite,
                    hasKeyPair: pqcManager.hasKeyPair
                )
                LabeledContent {
                    Text(pqcPolicyStatus.label)
                        .foregroundColor(SettingsView.pqcPolicyStatusColor(for: pqcPolicyStatus.tone))
                } label: {
                    Text("策略状态")
                }
                LabeledContent("运行状态", value: pqcPolicyStatus.detail)
                LabeledContent("当前套件", value: pqcManager.currentSuite.rawValue)
                LabeledContent("Provider", value: pqcManager.providerInfo)
                LabeledContent("安全层级", value: pqcManager.currentTier.rawValue)

                let selectedProviderAvailability = pqcManager
                    .providerAvailability(requestedProviderPreference)
                Picker("首选 KEM / Provider", selection: $requestedProviderPreference) {
                    ForEach(PQCProviderPreference.allCases) { preference in
                        let availability = pqcManager.providerAvailability(preference)
                        Text(
                            "\(Self.providerPreferenceLabel(preference)) · " +
                                (availability.isAvailable ? "可用" : "不可用")
                        )
                            .tag(preference)
                    }
                }

                Button {
                    applyProviderPreference()
                } label: {
                    if isApplyingProviderPreference {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在验证并切换…")
                        }
                    } else {
                        Text("应用首选套件")
                    }
                }
                .disabled(
                    isApplyingProviderPreference
                        || isApplyingProtocolIdentity
                        || !selectedProviderAvailability.isAvailable
                )

                Text(selectedProviderAvailability.detail)
                    .font(.footnote)
                    .foregroundColor(
                        selectedProviderAvailability.isAvailable
                            ? .secondary
                            : .orange
                    )

                if requestedProviderPreference == .qPeriaptBeta {
                    Text("Q-Periapt ABI2 为策略绑定 Beta 路径，仅在生产策略会话已验证且主协议身份为 ML-DSA-65 时启用；不满足条件会拒绝并回滚。")
                        .font(.footnote)
                        .foregroundColor(
                            requestedProtocolSigningAlgorithm == .mlDSA65
                                ? .secondary
                                : .orange
                        )
                } else if requestedProviderPreference == .xwingHybrid {
                    Text("X-Wing 将 ML-KEM-768 与 X25519 组合；仅在本机 Apple PQC 运行时自检通过时启用。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section("主协议身份签名") {
                Picker("ML-DSA 参数集", selection: $requestedProtocolSigningAlgorithm) {
                    Text("65 · Category 3").tag(ProtocolSigningAlgorithm.mlDSA65)
                    if Self.mlDSA87SoftwareAvailable {
                        Text("87 · Category 5").tag(ProtocolSigningAlgorithm.mlDSA87)
                    }
                }
                .pickerStyle(.segmented)

                if !Self.mlDSA87SoftwareAvailable {
                    Text("ML-DSA-87 需要 iOS 26+ 与包含 Apple PQC 的正式构建。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Toggle(
                    "使用 Secure Enclave 保护 ML-DSA 私钥",
                    isOn: $requestedSecureEnclave
                )
                .disabled(!IOSSecureEnclaveMLDSAIdentityFactory.isAvailable)

                if !IOSSecureEnclaveMLDSAIdentityFactory.isAvailable {
                    Text(
                        IOSSecureEnclaveMLDSAIdentityFactory.unavailabilityReason
                            ?? "此设备当前不能创建 Secure Enclave ML-DSA 密钥。"
                    )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Button {
                    applyProtocolIdentityConfiguration()
                } label: {
                    if isApplyingProtocolIdentity {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在生成并自检…")
                        }
                    } else {
                        Text("应用身份签名配置")
                    }
                }
                .disabled(
                    isApplyingProtocolIdentity
                        || isApplyingProviderPreference
                        || (requestedProtocolSigningAlgorithm == .mlDSA87
                            && !Self.mlDSA87SoftwareAvailable)
                        || (requestedSecureEnclave
                            && !IOSSecureEnclaveMLDSAIdentityFactory.isAvailable)
                )

                LabeledContent(
                    protocolIdentityRuntimeIsActive ? "已激活算法" : "已配置意图",
                    value: activeProtocolSigningAlgorithm.rawValue
                )
                LabeledContent(
                    protocolIdentityRuntimeIsActive ? "本机私钥" : "计划私钥",
                    value: activeProtocolSigningProtection == .secureEnclaveRequired
                        ? "Secure Enclave"
                        : "Keychain 软件密钥"
                )

                if protocolIdentityRequiresExplicitConfirmation {
                    Text("身份配置记录不完整、损坏或无法证明对应密钥槽。连接已停用；请重新选择并点击“应用身份签名配置”进行显式确认。")
                        .font(.footnote)
                        .foregroundColor(.red)
                } else if !protocolIdentityRuntimeIsActive {
                    Text("这是已配置意图；运行时恢复密钥并完成签名自检后才会标记为已激活。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }

                if activeProtocolSigningAlgorithm == .mlDSA87 {
                    if protocolIdentityRuntimeIsActive {
                        Text("本机 ML-DSA-87 主身份已恢复并通过签名自检。")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    } else {
                        Text("已配置 ML-DSA-87 主身份；运行时恢复密钥并完成签名自检后才会激活。")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    Text("跨网络会话要求对端精确绑定原始 87 公钥；尚未重新批准的连接会明确拒绝。其他路径若使用独立的 65 兼容身份，也不会冒充 87。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
                Text("Secure Enclave 仅约束所选主身份的本机私钥驻留；不宣称对端硬件证明，该精确密钥槽失败时不会回退到软件密钥。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
                    .onChange(of: pqcManager.enforcePQCHandshake) { _, _ in
                        reinitializePQCProvider()
                    }
                    .disabled(isApplyingProviderPreference || isApplyingProtocolIdentity)

                LabeledContent(
                    "允许经典降级（兼容旧设备）",
                    value: pqcManager.enforcePQCHandshake ? "关闭（严格 PQC）" : "关闭（Classic only）"
                )
                
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
                NavigationLink(destination: PQCMicroBenchView()) {
                    Label(RuntimeLocalization.string("PQC 自检 / 微基准"), systemImage: "waveform.path.ecg")
                }
                Text("原语级 microbench（encap/sign/verify/seal-open）固定为 warmup=10、N=1000、batches=3，导出 schema v3 JSON 到 artifact 管线。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                NavigationLink(destination: RealNetworkE2EBenchView()) {
                    Label(RuntimeLocalization.string("真实网络端到端微研究"), systemImage: "antenna.radiowaves.left.and.right")
                }
                Text("在 iPhone/iPad 上作为 client，连接到 Mac 上的测试 server，对比 classic(687B) 与 PQC(12,002B) 的端到端时延与失败类型，并导出 CSV 到 Artifacts 管线。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DashboardView.QuantumGlassBackground())
        .navigationTitle("后量子加密")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            requestedProviderPreference = PQCCryptoManager.currentProviderPreference()
            refreshProtocolIdentityPresentation()
        }
        .alert(
            "PQC 操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { presenting in
                    if !presenting {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    internal static func providerPreferenceLabel(
        _ preference: PQCProviderPreference
    ) -> String {
        switch preference {
        case .mlkem:
            return "ML-KEM-768（标准）"
        case .xwingHybrid:
            return "X-Wing 混合加密"
        case .qPeriaptBeta:
            return "Q-Periapt ABI2（Beta）"
        }
    }

    private func applyProviderPreference() {
        let preference = requestedProviderPreference
        isApplyingProviderPreference = true
        Task { @MainActor in
            defer { isApplyingProviderPreference = false }
            do {
                try await pqcManager.applyProviderPreference(preference)
                requestedProviderPreference = PQCCryptoManager.currentProviderPreference()
            } catch {
                requestedProviderPreference = PQCCryptoManager.currentProviderPreference()
                errorMessage = error.localizedDescription
                SkyBridgeLogger.shared.error(
                    "❌ PQC Provider 首选项应用失败: errorClass=\(String(reflecting: Swift.type(of: error)))"
                )
            }
        }
    }
    
    private func generateKeyPair() {
        Task {
            do {
                try await pqcManager.generateKeyPair()
            } catch {
                errorMessage = error.localizedDescription
                SkyBridgeLogger.shared.error("❌ PQC 密钥生成失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func regenerateKeys() {
        Task {
            do {
                try await pqcManager.regenerateKeyPair()
            } catch {
                errorMessage = error.localizedDescription
                SkyBridgeLogger.shared.error("❌ PQC 密钥重新生成失败: \(error.localizedDescription)")
            }
        }
    }

    private func reinitializePQCProvider() {
        Task {
            do {
                try await pqcManager.initialize()
            } catch {
                errorMessage = error.localizedDescription
                SkyBridgeLogger.shared.error("❌ PQC Provider 重新初始化失败: \(error.localizedDescription)")
            }
        }
    }

    private func applyProtocolIdentityConfiguration() {
        let algorithm = requestedProtocolSigningAlgorithm
        let protection: ProtocolSigningKeyProtection = requestedSecureEnclave
            ? .secureEnclaveRequired
            : .softwareKeychain
        isApplyingProtocolIdentity = true
        Task { @MainActor in
            defer { isApplyingProtocolIdentity = false }
            do {
                guard let authenticationPrincipal = authManager
                    .currentPathAuthenticationPrincipal else {
                    throw IOSCurrentPathDeviceActivationError
                        .authenticationStateChanged
                }
                try await IOSCurrentPathDeviceActivationCoordinator.shared
                    .activateCurrentIdentityIfNeeded(
                        authenticationPrincipal: authenticationPrincipal
                    )
                let expectedScope = SignalServerClientCompat
                    .IdentityRotationAuthenticationScope(
                        tenantID: authenticationPrincipal.tenantID,
                        userID: authenticationPrincipal.userID
                    )
                try await IOSCurrentPathDeviceIdentityRotationCoordinator.shared.rotate(
                    algorithm: algorithm,
                    protection: protection,
                    expectedScope: expectedScope
                )
                let committed = try await SkyBridgeiOSCore.shared
                    .committedActiveProtocolIdentitySnapshot()
                guard committed.algorithm == algorithm,
                      committed.protection == protection else {
                    throw IOSCurrentPathDeviceIdentityRotationError
                        .localConfigurationChanged
                }
                activeProtocolSigningAlgorithm = committed.algorithm
                activeProtocolSigningProtection = committed.protection
                protocolIdentityRuntimeIsActive = true
                do {
                    try await refreshLocalProtocolIdentityAdvertisements(
                        committed.snapshot
                    )
                    protocolIdentityRequiresExplicitConfirmation = false
                } catch {
                    protocolIdentityRequiresExplicitConfirmation = true
                    errorMessage = "协议身份已切换，但局域网广播已安全停用：\(error.localizedDescription)"
                }
            } catch IOSCurrentPathDeviceIdentityRotationError
                .localAuthorityCommittedRecoveryRequired(let reason) {
                var publicationFailure: String?
                if let committed = try? await SkyBridgeiOSCore.shared
                    .committedActiveProtocolIdentitySnapshot() {
                    activeProtocolSigningAlgorithm = committed.algorithm
                    activeProtocolSigningProtection = committed.protection
                    protocolIdentityRuntimeIsActive = true
                    do {
                        try await refreshLocalProtocolIdentityAdvertisements(
                            committed.snapshot
                        )
                    } catch {
                        publicationFailure = error.localizedDescription
                    }
                }
                protocolIdentityRequiresExplicitConfirmation = true
                if let publicationFailure {
                    errorMessage = "协议身份已切换；恢复记录待清理，局域网广播已安全停用：\(reason)；\(publicationFailure)"
                } else {
                    errorMessage = "协议身份已切换，但恢复记录仍待清理：\(reason)"
                }
            } catch {
                errorMessage = error.localizedDescription
                SkyBridgeLogger.shared.error(
                    "Protocol signing identity configuration failed: \(error.localizedDescription)"
                )
            }
        }
    }

    @MainActor
    private func refreshLocalProtocolIdentityAdvertisements(
        _ authority: ProtocolIdentitySnapshot
    ) async throws {
        var failures: [String] = []
        do {
            try await P2PConnectionManager.instance
                .refreshAdvertisingAuthorityIfActive(authority)
        } catch {
            failures.append("P2P: \(error.localizedDescription)")
        }
        do {
            try await FileTransferRuntime.shared
                .refreshAdvertisingAuthorityIfActive(authority)
        } catch {
            failures.append("FileTransfer: \(error.localizedDescription)")
        }
        guard failures.isEmpty else {
            throw NSError(
                domain: "SettingsView.ProtocolIdentityAdvertisement",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "部分本地身份广播未完成并已撤销对应能力：\(failures.joined(separator: "; "))"
                ]
            )
        }
    }

    private static var mlDSA87SoftwareAvailable: Bool {
#if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, *) {
            return true
        }
#endif
        return false
    }

    @MainActor
    private func refreshProtocolIdentityPresentation() {
        let configurationResolution = ProtocolSigningIdentityPolicy
            .configurationResolution()
        let persistedAlgorithm = ProtocolSigningIdentityPolicy.requestedPQCAlgorithm()
        let persistedProtection = ProtocolSigningIdentityPolicy.requestedProtection()
        requestedProtocolSigningAlgorithm = persistedAlgorithm
        requestedSecureEnclave = persistedProtection == .secureEnclaveRequired
        if SkyBridgeiOSCore.shared.isInitialized,
           let runtimeAlgorithm = SkyBridgeiOSCore.shared.signatureProvider?.signatureAlgorithm,
           runtimeAlgorithm != .ed25519 {
            activeProtocolSigningAlgorithm = runtimeAlgorithm
            activeProtocolSigningProtection =
                SkyBridgeiOSCore.shared.activeProtocolSigningKeyProtection
            protocolIdentityRuntimeIsActive = true
        } else {
            activeProtocolSigningAlgorithm = persistedAlgorithm
            activeProtocolSigningProtection = persistedProtection
            protocolIdentityRuntimeIsActive = false
        }
        protocolIdentityRequiresExplicitConfirmation = configurationResolution
            .needsExplicitConfirmation
    }
}

// MARK: - Placeholder Views

struct DiscoverySettingsView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @StateObject private var settings = SettingsManager.instance
    @State private var discoveryError: String?

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
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
            .navigationTitle("设备发现")
            .alert(
                "发现服务启动失败",
                isPresented: Binding(
                    get: { discoveryError != nil },
                    set: { presenting in
                        if !presenting {
                            discoveryError = nil
                        }
                    }
                )
            ) {
                Button("确定", role: .cancel) {
                    discoveryError = nil
                }
            } message: {
                Text(discoveryError ?? "")
            }
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
                do {
                    try await discoveryManager.startDiscovery(mode: mode)
                } catch {
                    discoveryError = error.localizedDescription
                    SkyBridgeLogger.shared.error("❌ 设备发现启动失败: \(error.localizedDescription)")
                }
            } else {
                discoveryManager.stopDiscovery()
            }
        }
    }
}

struct TrustedDevicesView: View {
    @EnvironmentObject private var discoveryManager: DeviceDiscoveryManager
    @StateObject private var store = TrustedDeviceStore.shared
    @State private var pairingDeviceIds: Set<String> = []
    @State private var pairingError: String?
    @State private var trustMutationError: String?

    private var activeTrustedDevices: [TrustedDeviceStore.TrustedDevice] {
        store.trustedDevices.filter { lifecycleState(for: $0) == .active }
    }

    private var inactiveTrustedDevices: [TrustedDeviceStore.TrustedDevice] {
        store.trustedDevices.filter { lifecycleState(for: $0) != .active }
    }

    var body: some View {
        List {
            if store.trustedDevices.isEmpty {
                Section {
                    Text("暂无受信任设备。你可以在设备验证成功后自动加入，或在下面从已发现设备发起设备确认码配对。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Section("受信任设备") {
                    if activeTrustedDevices.isEmpty {
                        Text("暂无有效受信任设备。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                } else {
                    ForEach(activeTrustedDevices) { dev in
                        VStack(alignment: .leading, spacing: 8) {
                            trustedDeviceRow(dev)
                            Button {
                                repairP2PTrust(dev)
                            } label: {
                                Text("修复 P2P 信任")
                            }
                            .font(.caption)
                        }
                    }
                    .onDelete { idxSet in
                        let devices = activeTrustedDevices
                        for idx in idxSet {
                            forgetTrustedDevice(devices[idx])
                            }
                        }
                    }
                }

                if !inactiveTrustedDevices.isEmpty {
                    Section("需要处理的设备") {
                        ForEach(inactiveTrustedDevices) { dev in
                            VStack(alignment: .leading, spacing: 8) {
                                trustedDeviceRow(dev, status: lifecycleLabel(for: dev))
                                HStack {
                                    Button {
                                        repairP2PTrust(dev)
                                    } label: {
                                        Text("修复 P2P 信任")
                                    }
                                    Button(role: .destructive) {
                                        forgetTrustedDevice(dev)
                                    } label: {
                                        Text("彻底忘记设备")
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .onDelete { idxSet in
                            let devices = inactiveTrustedDevices
                            for idx in idxSet {
                                forgetTrustedDevice(devices[idx])
                            }
                        }
                    }
                }
            }

            Section("从已发现设备添加") {
                let candidates = discoveryManager.discoveredDevices.filter { !$0.isTrusted }
                if candidates.isEmpty {
                    Text("当前没有可添加的设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates) { dev in
                        Button {
                            startDeviceConfirmationPairing(dev)
                        } label: {
                            HStack {
                                Text(dev.name)
                                Spacer()
                                if pairingDeviceIds.contains(dev.id) {
                                    ProgressView()
                                }
                                Text("设备确认码配对")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(dev.platform.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(pairingDeviceIds.contains(dev.id))
                    }
                }
                if let pairingError {
                    Text(pairingError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if !store.trustedDevices.isEmpty {
                Section {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await P2PConnectionManager.instance.forgetAllTrustedDevices()
                            } catch {
                                trustMutationError = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("清空受信任设备")
                    }
                }
            }
        }
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
            .navigationTitle("受信任的设备")
            .alert(
                "无法更新受信任设备",
                isPresented: Binding(
                    get: { trustMutationError != nil },
                    set: { if !$0 { trustMutationError = nil } }
                )
            ) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(trustMutationError ?? "未知错误")
            }
    }

    private func forgetTrustedDevice(_ device: TrustedDeviceStore.TrustedDevice) {
        Task {
            do {
                try await P2PConnectionManager.instance.forgetTrustedDevice(deviceId: device.id)
            } catch {
                trustMutationError = error.localizedDescription
            }
        }
    }

    private func repairP2PTrust(_ device: TrustedDeviceStore.TrustedDevice) {
        Task {
            await P2PConnectionManager.instance.repairP2PTrustForTrustedDevice(deviceIds: [device.id])
        }
    }

    @MainActor
    private func startDeviceConfirmationPairing(_ device: DiscoveredDevice) {
        guard !pairingDeviceIds.contains(device.id) else { return }
        pairingDeviceIds.insert(device.id)
        pairingError = nil

        Task {
            do {
                try await P2PConnectionManager.instance.connect(to: device)
            } catch {
                let message = P2PConnectionManager.localizedConnectionErrorMessage(error)
                await MainActor.run {
                    pairingError = message
                }
            }
            await MainActor.run {
                _ = pairingDeviceIds.remove(device.id)
            }
        }
    }

    @ViewBuilder
    private func trustedDeviceRow(
        _ dev: TrustedDeviceStore.TrustedDevice,
        status: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dev.name).font(.headline)
            HStack(spacing: 8) {
                Text(dev.platform.displayName)
                if let ip = dev.ipAddress { Text(ip) }
                if let status {
                    Text(status)
                        .foregroundColor(.orange)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Text("\(RuntimeLocalization.string("设备标识")): \(dev.id)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func lifecycleState(
        for dev: TrustedDeviceStore.TrustedDevice
    ) -> TrustedDeviceStore.CurrentPathLifecycleState {
        dev.currentPathLifecycleState ?? .active
    }

    private func lifecycleLabel(for dev: TrustedDeviceStore.TrustedDevice) -> String {
        switch lifecycleState(for: dev) {
        case .active:
            return "已受信任"
        case .reverificationRequired:
            return "需要重新验证"
        case .quarantined:
            return "已隔离"
        case .revoked:
            return "已撤销"
        }
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
                            Task {
                                do {
                                    try await connectionManager.startListening()
                                    ICloudDevicePresenceService.shared.refreshNow()
                                } catch {
                                    ICloudDevicePresenceService.shared.refreshNow()
                                    SkyBridgeLogger.shared.error(
                                        "❌ 启用后台连接时 P2P 监听器启动失败: \(error.localizedDescription)"
                                    )
                                }
                            }
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
                    Text("512 KB").tag(512 * 1024)
                    Text("750 KiB").tag(750 * 1024)
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
                Text("内联剪贴板受 P2P 控制帧限制，最大 750 KiB；更大内容请使用文件传输。")
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
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
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
                    Text("512 KB").tag(512 * 1024)
                    Text("750 KiB").tag(750 * 1024)
                }
                .disabled(!settings.clipboardSyncEnabled)

                if settings.clipboardContentSizeWasMigrated {
                    Text("旧版的大剪贴板设置已迁移到 750 KiB 安全上限；更大内容请使用文件传输。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

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
                    Text("\(RuntimeLocalization.string("MIME 类型")): \(mime)")
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
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
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
    @StateObject private var cloudKitSync = CloudKitSyncManager.instance

    var body: some View {
        Form {
            Section {
                Toggle("启用 CloudKit 同步", isOn: $settings.enableCloudKitSync)
            } footer: {
                Text("未在 Xcode Signing 中开启 iCloud/CloudKit 能力时，建议保持关闭。")
            }

            if settings.enableCloudKitSync {
                Section("同步状态") {
                    if cloudKitSync.isSyncing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在同步受信任设备…")
                        }
                    } else if let errorMessage = cloudKitSync.lastSyncErrorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    } else if let lastSyncDate = cloudKitSync.lastSyncDate {
                        Label(
                            "上次成功：\(lastSyncDate.formatted(date: .abbreviated, time: .standard))",
                            systemImage: "checkmark.icloud.fill"
                        )
                        .foregroundColor(.green)
                        .font(.caption)
                    } else {
                        Text("尚未完成同步")
                            .foregroundColor(.secondary)
                    }

                    Button("立即同步") {
                        startManualCloudKitSync()
                    }
                    .disabled(cloudKitSync.isSyncing)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DashboardView.QuantumGlassBackground())
        .navigationTitle("iCloud 同步")
        .onChange(of: settings.enableCloudKitSync) { _, enabled in
            if enabled {
                startManualCloudKitSync()
            }
        }
    }

    private func startManualCloudKitSync() {
        Task { @MainActor in
            do {
                try await cloudKitSync.refreshTrustedDevices(trigger: .manual)
            } catch {
                // The manager publishes the durable error state shown above;
                // this boundary records context without pretending success.
                SkyBridgeLogger.shared.error(
                    "⛔️ 手动 CloudKit 信任同步失败：\(CloudKitSyncManager.safeErrorSummary(error))"
                )
            }
        }
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
                    Task { await save() }
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
            } footer: {
                Text("手机号验证码登录依赖 Supabase Auth 的 send_sms hook。生产环境请将 hook 指向 SkyBridge 服务端，再由服务端安全地调用 Aliyun SMS。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DashboardView.QuantumGlassBackground())
        .navigationTitle("Supabase 配置")
        .task { await load() }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func load() async {
        do {
            let cfg = try await KeychainManager.shared.retrieveSupabaseConfig()
            supabaseURL = cfg.url
            anonKey = cfg.anonKey
        } catch KeychainError.itemNotFound {
            return
        } catch {
            alertMessage = "读取失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    private func save() async {
        do {
            let urlString = supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyString = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !keyString.isEmpty else {
                alertMessage = "SUPABASE_ANON_KEY 不能为空"
                showAlert = true
                return
            }
            guard let url = URL(string: urlString), SupabaseService.Configuration.isValidSupabaseURL(url) else {
                alertMessage = "SUPABASE_URL 无效（需 https 且 host 非空）"
                showAlert = true
                return
            }
            
            try await KeychainManager.shared.storeSupabaseConfig(url: urlString, anonKey: keyString)
            SupabaseService.shared.updateConfiguration(
                .init(url: url, anonKey: keyString)
            )
            
            supabaseURL = urlString
            anonKey = keyString

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
                    Text(RuntimeLocalization.string("调试")).tag(LogLevel.debug)
                    Text(RuntimeLocalization.string("信息")).tag(LogLevel.info)
                    Text(RuntimeLocalization.string("警告")).tag(LogLevel.warning)
                    Text(RuntimeLocalization.string("错误")).tag(LogLevel.error)
                }
            } header: {
                Text("过滤")
            }

            Section {
                let text = store.exportText(minLevel: minLevel, search: query)
                ShareLink(item: text) {
                    Label(RuntimeLocalization.string("导出日志（分享）"), systemImage: "square.and.arrow.up")
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
            .scrollContentBackground(.hidden)
            .background(DashboardView.QuantumGlassBackground())
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
        ZStack {
            DashboardView.QuantumGlassBackground()
            Text("开源许可")
        }
        .navigationTitle("开源许可")
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ZStack {
            DashboardView.QuantumGlassBackground()
            Text("隐私政策")
        }
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
