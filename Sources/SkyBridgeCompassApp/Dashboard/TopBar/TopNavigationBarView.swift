import SwiftUI
import SkyBridgeCore
import os.log

/// 顶部导航栏视图
@available(macOS 14.0, *)
public struct TopNavigationBarView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

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
 // 应用图标和标题
            HStack(spacing: 12) {
 // 使用Bundle.module加载PNG图标文件
                CustomGlobeIconView(cornerRadius: 6)
                    .frame(width: 28, height: 28)

                Text(LocalizationManager.shared.localizedString("app.name"))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(themeConfiguration.primaryTextColor)
                    .id("app-title") // 添加稳定的ID，避免重复创建
            }

            Spacer()

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

 // MARK: - 连接状态指示器
    private var connectionStatusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActuallyConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .animation(themeConfiguration.easeAnimation, value: isActuallyConnected)

            if isActuallyConnected, let detail = connectionDetailText, !detail.isEmpty {
                Text(LocalizationManager.shared.localizedString("device.status.connected") + " · " + detail)
                    .font(.caption)
                    .foregroundColor(themeConfiguration.secondaryTextColor)
            } else {
            Text(isActuallyConnected ? LocalizationManager.shared.localizedString("device.status.connected") : LocalizationManager.shared.localizedString("status.disconnected"))
                .font(.caption)
                .foregroundColor(themeConfiguration.secondaryTextColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeConfiguration.cardBackgroundColor, in: Capsule())
        .overlay(
            Capsule()
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

    private var isActuallyConnected: Bool {
        if appModel.connectionStatus == .connected {
            return true
        }
        return unifiedDeviceManager.onlineDevices.contains { device in
            !device.isLocalDevice && device.connectionStatus == .connected
        }
    }

    private var connectionDetailText: String? {
        if let detail = appModel.connectionDetail, !detail.isEmpty {
            return detail
        }
        let connectedPeer = unifiedDeviceManager.onlineDevices
            .filter { !$0.isLocalDevice && $0.connectionStatus == .connected }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .first
        guard let connectedPeer else {
            return nil
        }
        if let kind = connectedPeer.lastCryptoKind, let suite = connectedPeer.lastCryptoSuite {
            return "\(kind) · \(suite) · \(connectedPeer.guardStatus ?? "守护中")"
        }
        return connectedPeer.name
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(themeConfiguration.cardBackgroundColor, in: Capsule())
        .overlay(
            Capsule()
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
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
                .foregroundColor(themeConfiguration.currentTheme.primaryColor)
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
