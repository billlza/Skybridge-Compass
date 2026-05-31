import SwiftUI
import SkyBridgeCore
import os.log

/// 顶部导航栏视图
@available(macOS 14.0, *)
public struct TopNavigationBarView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var networkStatusService = TopBarNetworkStatusService.shared
    @State private var networkStatusConsumerID = UUID()

    @Binding var showManualConnectSheet: Bool
    @Binding var manualIP: String
    @Binding var manualPort: String
    @Binding var manualCode: String
    @Binding var realtimeFPS: String

    public init(
        showManualConnectSheet: Binding<Bool>,
        manualIP: Binding<String>,
        manualPort: Binding<String>,
        manualCode: Binding<String>,
        realtimeFPS: Binding<String>
    ) {
        self._showManualConnectSheet = showManualConnectSheet
        self._manualIP = manualIP
        self._manualPort = manualPort
        self._manualCode = manualCode
        self._realtimeFPS = realtimeFPS
    }

    public var body: some View {
        HStack {
            Spacer()

            if settingsManager.showTopBarIPLocation {
                ipLocationIndicator
            }

            if settingsManager.showTopBarNetworkSpeed {
                networkSpeedIndicator
            }

            if settingsManager.showTopBarNetworkLatency {
                networkLatencyIndicator
            }

 // 连接状态指示器
            connectionStatusIndicator

 // 在"未连接"和"通知中心"之间显示实时FPS（仅受设置开关控制）
            if SettingsManager.shared.showRealtimeFPS {
                fpsIndicator
            }

 // 通知铃铛（在"刷子"左侧）
            NotificationBellView()

 // 主题切换按钮（刷子）
            themeToggleButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(themeConfiguration.cardBackgroundMaterial, in: Rectangle())
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeConfiguration.borderColor),
            alignment: .bottom
        )
        .zIndex(1) // 顶部导航置前，避免被顶部提示覆盖
 // 订阅Metal渲染链路的FPS通知
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MetalFPSUpdated"))) { note in
            if let fps = note.userInfo?["fps"] as? String { realtimeFPS = fps }
        }
        .onAppear {
            updateNetworkStatusConsumerRegistration()
        }
        .onChange(of: shouldRunNetworkStatusService) { _, shouldRun in
            if shouldRun {
                networkStatusService.activateConsumer(networkStatusConsumerID)
            } else {
                networkStatusService.deactivateConsumer(networkStatusConsumerID)
            }
        }
        .onDisappear {
            networkStatusService.deactivateConsumer(networkStatusConsumerID)
        }
 // 手动连接输入弹窗
        .sheet(isPresented: $showManualConnectSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizationManager.shared.localizedString("manualConnect.title"))
                    .font(.headline)
                TextField(LocalizationManager.shared.localizedString("manualConnect.ipAddress"), text: $manualIP)
                    .textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("manualConnect.port"), text: $manualPort)
                    .textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("manualConnect.pairingCode"), text: $manualCode)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(LocalizationManager.shared.localizedString("action.cancel")) { showManualConnectSheet = false }
                    Button(LocalizationManager.shared.localizedString("device.action.connect")) {
                        showManualConnectSheet = false
                        let port = UInt16(manualPort) ?? 0
                        Task { await appModel.manualConnect(ip: manualIP, port: port, pairingCode: manualCode) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private var shouldRunNetworkStatusService: Bool {
        settingsManager.showTopBarIPLocation
            || settingsManager.showTopBarNetworkSpeed
            || settingsManager.showTopBarNetworkLatency
    }

    private func updateNetworkStatusConsumerRegistration() {
        if shouldRunNetworkStatusService {
            networkStatusService.activateConsumer(networkStatusConsumerID)
        } else {
            networkStatusService.deactivateConsumer(networkStatusConsumerID)
        }
    }

 // MARK: - 连接状态指示器
    private var connectionStatusIndicator: some View {
        let presentation = appModel.topConnectionPresentation

        return HStack(spacing: 8) {
            Circle()
                .fill(connectionIndicatorColor(for: presentation.phase))
                .frame(width: 8, height: 8)
                .animation(themeConfiguration.easeAnimation, value: presentation.phase)

            if settingsManager.showConnectionStats,
               presentation.phase != .disconnected,
               let detail = presentation.detailText,
               !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(themeConfiguration.secondaryTextColor)
            } else {
                Text(presentation.statusText)
                    .font(.caption)
                    .foregroundColor(themeConfiguration.secondaryTextColor)
            }
        }
        .topBarGlassPill(themeConfiguration: themeConfiguration, horizontalPadding: 12)
    }

    private func connectionIndicatorColor(for phase: ConnectionPresentationPhase) -> Color {
        switch phase {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

 // 实时FPS展示小控件（位于顶部导航栏中间）
    private var fpsIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .font(.caption)
                .foregroundColor(.orange)
            Text(realtimeFPS.isEmpty ? "— FPS" : realtimeFPS)
                .font(.caption)
                .foregroundColor(themeConfiguration.secondaryTextColor)
        }
        .topBarGlassPill(themeConfiguration: themeConfiguration)
    }

    private var ipLocationIndicator: some View {
        let location = networkStatusService.snapshot.location
        return topBarStatusPill(
            icon: location.isSystemProxyEnabled ? "network.badge.shield.half.filled" : "network",
            iconColor: location.isSystemProxyEnabled ? .orange : .blue,
            text: ipLocationText(location),
            help: ipLocationHelp(location)
        )
    }

    private var networkSpeedIndicator: some View {
        let speed = networkStatusService.snapshot.speed
        return topBarStatusPill(
            icon: "arrow.down.arrow.up",
            iconColor: .cyan,
            text: networkSpeedText(speed),
            help: networkSpeedHelp(speed)
        )
    }

    private var networkLatencyIndicator: some View {
        let latency = networkStatusService.snapshot.latency
        return topBarStatusPill(
            icon: "timer",
            iconColor: .mint,
            text: networkLatencyText(latency),
            help: networkLatencyHelp(latency)
        )
    }

    private func topBarStatusPill(
        icon: String,
        iconColor: Color,
        text: String,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(iconColor)
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(themeConfiguration.secondaryTextColor)
        }
        .frame(maxWidth: 180)
        .topBarGlassPill(themeConfiguration: themeConfiguration)
        .help(help)
    }

    private func ipLocationText(_ location: TopBarNetworkLocationStatus) -> String {
        switch location.status {
        case .idle, .loading:
            return localized("topbar.network.ipLocation.pending")
        case .ready:
            let city = nonEmpty(location.city) ?? nonEmpty(location.countryCode) ?? localized("topbar.network.unknownCity")
            let proxy = location.isSystemProxyEnabled
                ? localized("topbar.network.proxy.enabled")
                : localized("topbar.network.proxy.disabled")
            return localizedFormat("topbar.network.ipLocation.ready", city, proxy)
        case .failed:
            return localized("topbar.network.ipLocation.failed")
        }
    }

    private func ipLocationHelp(_ location: TopBarNetworkLocationStatus) -> String {
        switch location.status {
        case .idle:
            return localized("topbar.network.ipLocation.help.idle")
        case .loading:
            return localized("topbar.network.ipLocation.help.loading")
        case .ready:
            let ip = nonEmpty(location.publicIPAddress) ?? localized("topbar.network.unknownIp")
            let city = nonEmpty(location.city) ?? localized("topbar.network.unknownCity")
            let proxy = location.isSystemProxyEnabled
                ? localized("topbar.network.proxy.help.enabled")
                : localized("topbar.network.proxy.help.disabled")
            return localizedFormat("topbar.network.ipLocation.help.ready", ip, city, proxy)
        case .failed(let message):
            return localizedFormat("topbar.network.ipLocation.help.failed", message)
        }
    }

    private func networkSpeedText(_ speed: TopBarNetworkSpeedStatus) -> String {
        switch speed.status {
        case .idle, .loading:
            return localized("topbar.network.speed.pending")
        case .ready:
            return localizedFormat(
                "topbar.network.speed.ready",
                formatByteRate(speed.inboundBytesPerSecond),
                formatByteRate(speed.outboundBytesPerSecond)
            )
        case .failed:
            return localized("topbar.network.speed.failed")
        }
    }

    private func networkSpeedHelp(_ speed: TopBarNetworkSpeedStatus) -> String {
        switch speed.status {
        case .idle:
            return localized("topbar.network.speed.help.idle")
        case .loading:
            return localized("topbar.network.speed.help.loading")
        case .ready:
            return localizedFormat(
                "topbar.network.speed.help.ready",
                formatByteRate(speed.inboundBytesPerSecond),
                formatByteRate(speed.outboundBytesPerSecond)
            )
        case .failed(let message):
            return localizedFormat("topbar.network.speed.help.failed", message)
        }
    }

    private func networkLatencyText(_ latency: TopBarNetworkLatencyStatus) -> String {
        switch latency.status {
        case .idle, .loading:
            return localized("topbar.network.latency.pending")
        case .ready:
            guard let milliseconds = latency.milliseconds else {
                return localized("topbar.network.latency.failed")
            }
            return localizedFormat("topbar.network.latency.ready", String(milliseconds))
        case .failed:
            return localized("topbar.network.latency.failed")
        }
    }

    private func networkLatencyHelp(_ latency: TopBarNetworkLatencyStatus) -> String {
        switch latency.status {
        case .idle:
            return localized("topbar.network.latency.help.idle")
        case .loading:
            return localized("topbar.network.latency.help.loading")
        case .ready:
            guard let milliseconds = latency.milliseconds else {
                return localized("topbar.network.latency.help.failedUnavailable")
            }
            return localizedFormat("topbar.network.latency.help.ready", String(milliseconds))
        case .failed(let message):
            return localizedFormat("topbar.network.latency.help.failed", message)
        }
    }

    private func formatByteRate(_ bytesPerSecond: UInt64?) -> String {
        guard let bytesPerSecond else { return "— B/s" }
        let value = Double(bytesPerSecond)
        if value >= 1_000_000_000 {
            return String(format: "%.1f GB/s", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f KB/s", value / 1_000)
        }
        return String(format: "%.0f B/s", value)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func localized(_ key: String) -> String {
        localizationManager.localizedString(key)
    }

    private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: localizationManager.locale, arguments: arguments)
    }

 // MARK: - 主题切换按钮
    private var themeToggleButton: some View {
        Menu {
            ForEach(ThemeConfiguration.AppTheme.allCases) { theme in
                Button(action: {
                    themeConfiguration.switchToTheme(theme)
                }) {
                    HStack {
                        Text(theme.rawValue)
                        if theme == themeConfiguration.currentTheme {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button(action: {
                selectCustomBackground()
            }) {
                HStack {
                    Text(LocalizationManager.shared.localizedString("theme.selectBackground"))
                    Image(systemName: "photo")
                }
            }

            Divider()

            Button(action: {
                themeConfiguration.toggleAnimations()
            }) {
                HStack {
                    Text(LocalizationManager.shared.localizedString("theme.animations"))
                    if themeConfiguration.enableAnimations {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button(action: {
                themeConfiguration.toggleGlassEffects()
            }) {
                HStack {
                    Text(LocalizationManager.shared.localizedString("theme.glassEffects"))
                    if themeConfiguration.enableGlassEffect {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Image(systemName: "paintbrush.fill")
                .font(.title3)
                .foregroundColor(themeConfiguration.accentColor)
                .padding(8)
                .background(themeConfiguration.cardBackgroundColor, in: Circle())
                .overlay(
                    Circle()
                        .stroke(themeConfiguration.borderColor, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private func selectCustomBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                themeConfiguration.setCustomBackgroundImage(path: url.path(percentEncoded: false))
            }
        }
    }
}

@available(macOS 14.0, *)
private struct TopBarGlassPillModifier: ViewModifier {
    let themeConfiguration: ThemeConfiguration
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        } else {
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(themeConfiguration.cardBackgroundColor, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(themeConfiguration.borderColor, lineWidth: 1)
                )
        }
    }
}

@available(macOS 14.0, *)
private extension View {
    func topBarGlassPill(
        themeConfiguration: ThemeConfiguration,
        horizontalPadding: CGFloat = 10
    ) -> some View {
        modifier(
            TopBarGlassPillModifier(
                themeConfiguration: themeConfiguration,
                horizontalPadding: horizontalPadding
            )
        )
    }
}
