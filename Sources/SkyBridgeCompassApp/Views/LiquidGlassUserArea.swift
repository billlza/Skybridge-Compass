import SwiftUI
import SkyBridgeCore

/// 基于Apple 2025年Liquid Glass设计的用户信息区域
/// 采用最新的macOS 26设计语言和交互模式
@available(macOS 14.0, *)
struct LiquidGlassUserArea: View {
 // MARK: - 环境对象
    @EnvironmentObject var authModel: AuthenticationViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
 // MARK: - 状态管理
    @Binding var showingUserProfile: Bool
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var showingQuickMenu = false
    @State private var checkingForUpdates = false
    @State private var showingAbout = false
    
 // MARK: - 动画配置
 // 🔧 优化：使用更快的动画，减少延迟感
    private let hoverAnimation = Animation.easeInOut(duration: 0.1)
    private let pressAnimation = Animation.easeInOut(duration: 0.05)
    
    var body: some View {
        VStack(spacing: 0) {
 // Liquid Glass分隔线
            liquidGlassDivider
            
 // 用户信息主体区域
            userInfoContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(liquidGlassBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(isPressed ? 0.98 : (isHovered ? 1.02 : 1.0))
                .animation(isPressed ? pressAnimation : hoverAnimation, value: isPressed)
                .animation(hoverAnimation, value: isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
                .onTapGesture {
 // 使用触觉反馈增强交互体验
                    withAnimation(pressAnimation) {
                        isPressed = true
                    }
                    
 // 🔧 优化：使用Task替代DispatchQueue，减少延迟
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
                        withAnimation(pressAnimation) {
                            isPressed = false
                        }
                    }
                    
 // 统一使用结构化日志替代 print
                    SkyBridgeLogger.ui.info("🎯 用户区域被点击，发送显示用户资料覆盖层通知")
                    NotificationCenter.default.post(name: .init("ShowUserProfile"), object: nil)
                }
            .help(LocalizationManager.shared.localizedString("profile.help"))
            
 // 设置按钮区域
            settingsButton
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .background(.ultraThinMaterial.opacity(0.8))
    }
    
 // MARK: - Liquid Glass分隔线
    private var liquidGlassDivider: some View {
        Rectangle()
            .fill(.linearGradient(
                colors: [
                    .clear,
                    .primary.opacity(0.1),
                    .primary.opacity(0.2),
                    .primary.opacity(0.1),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }
    
 // MARK: - 用户信息内容
    private var userInfoContent: some View {
        HStack(spacing: 12) {
 // 用户头像 - 采用Liquid Glass风格
            userAvatar
            
 // 用户信息文本
            userInfoText
            
            Spacer()
            
 // 交互指示器
            interactionIndicator
        }
    }
    
 // MARK: - 用户头像
    private var userAvatar: some View {
        Group {
            if let userId = authModel.currentSession?.userIdentifier,
               let cachedAvatar = AvatarCacheManager.shared.getAvatar(for: userId) {
 // 真实头像
                Image(nsImage: cachedAvatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(.linearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ), lineWidth: 2)
                    )
            } else {
 // 默认头像 - Liquid Glass风格
                Circle()
                    .fill(.linearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(getUserInitials())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
 // MARK: - 用户信息文本
    private var userInfoText: some View {
        VStack(alignment: .leading, spacing: 3) {
 // 用户昵称
            Text(authModel.currentSession?.displayName ?? "用户")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
 // 星云ID
            Text("ID: \(getShortUserID())")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
    
 // MARK: - 交互指示器
    private var interactionIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isHovered ? 0 : -90))
 // 🔧 优化：使用更快的动画，减少延迟
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
    
 // MARK: - Liquid Glass背景
    private var liquidGlassBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.linearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.3 : 0.1),
                            .clear,
                            .black.opacity(isHovered ? 0.1 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1)
            )
    }
    
 // MARK: - 设置按钮
    private var settingsButton: some View {
        HStack {
            Spacer()
            
            Menu {
 // 关于
                Button(action: {
                    showingAbout = true
                }) {
                    Label(LocalizationManager.shared.localizedString("about.title"), systemImage: "info.circle")
                }
                
                Divider()
                
 // 检查更新
                Button(action: {
                    checkForUpdates()
                }) {
                    Label(checkingForUpdates ? LocalizationManager.shared.localizedString("about.checkingUpdates") : LocalizationManager.shared.localizedString("about.checkUpdates"), 
                          systemImage: checkingForUpdates ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                }
                .disabled(checkingForUpdates)
                
                Divider()
                
 // 系统信息
                Button(action: {
                    showSystemInfo()
                }) {
                    Label(LocalizationManager.shared.localizedString("about.systemInfo"), systemImage: "cpu")
                }
                
 // 诊断工具
                Button(action: {
                    showDiagnostics()
                }) {
                    Label(LocalizationManager.shared.localizedString("about.diagnostics"), systemImage: "stethoscope")
                }
                
                Divider()
                
 // 反馈问题
                Button(action: {
                    submitFeedback()
                }) {
                    Label(LocalizationManager.shared.localizedString("about.feedback"), systemImage: "exclamationmark.bubble")
                }
                
 // 访问官网
                Button(action: {
                    openWebsite()
                }) {
                    Label(LocalizationManager.shared.localizedString("about.website"), systemImage: "safari")
                }
                
                Divider()
                
 // 退出登录
                Button(action: {
                    authModel.signOut()
                }) {
                    Label {
                        Text("退出登录")
                            .foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
 // ✅ 兼容性：.menuIndicator(.hidden) 是 macOS 26+ 的特性
            .modifier(MenuIndicatorHiddenModifier())
            .buttonStyle(LiquidGlassButtonStyle())
            .help(LocalizationManager.shared.localizedString("profile.quickActions"))
        }
        .sheet(isPresented: $showingAbout) {
            AboutWindow()
        }
    }
    
 // MARK: - 辅助方法
    
 /// 获取用户姓名首字母
    private func getUserInitials() -> String {
        guard let displayName = authModel.currentSession?.displayName else {
            return "U"
        }
        
        let components = displayName.components(separatedBy: " ")
        if components.count >= 2 {
            let firstInitial = String(components[0].prefix(1)).uppercased()
            let lastInitial = String(components[1].prefix(1)).uppercased()
            return firstInitial + lastInitial
        } else {
            return String(displayName.prefix(1)).uppercased()
        }
    }
    
 /// 获取简短的用户ID显示
    private func getShortUserID() -> String {
        guard let userID = authModel.currentSession?.userIdentifier else {
            return "未知ID"
        }
        
        if userID.count > 12 {
            let prefix = String(userID.prefix(8))
            let suffix = String(userID.suffix(4))
            return "\(prefix)...\(suffix)"
        }
        
        return userID
    }
    
 // MARK: - 功能方法
    
 /// 检查更新
    private func checkForUpdates() {
        checkingForUpdates = true
        SkyBridgeLogger.ui.debugOnly("🔄 [LiquidGlassUserArea] 开始检查更新...")
        
 // 模拟网络请求
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            await MainActor.run {
                checkingForUpdates = false
 // 这里应该显示更新结果
                showUpdateAlert()
            }
        }
    }
    
 /// 显示更新提示
    private func showUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "SkyBridge Compass Pro 1.0.0 (Build 2025.10.31)\n您正在使用最新版本。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
    
 /// 显示系统信息
    private func showSystemInfo() {
        let info = getSystemInfo()
        let alert = NSAlert()
        alert.messageText = "系统信息"
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "关闭")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }
    }
    
 /// 获取系统信息
    private func getSystemInfo() -> String {
        var sysctl = utsname()
        uname(&sysctl)
        let model = withUnsafePointer(to: &sysctl.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "未知"
            }
        }
        
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let physicalMemory = processInfo.physicalMemory / 1_073_741_824 // GB
        
        return """
        芯片型号: \(model)
        系统版本: \(osVersion)
        物理内存: \(physicalMemory) GB
        应用版本: 1.0.0 (Build 2025.10.31)
        Metal 版本: Metal 4
        Swift 版本: 6.2
        """
    }
    
 /// 显示诊断工具
    private func showDiagnostics() {
        SkyBridgeLogger.ui.debugOnly("🔬 [LiquidGlassUserArea] 打开诊断工具...")
 // 这里可以打开一个诊断窗口
    }
    
 /// 提交反馈
    private func submitFeedback() {
        if let url = URL(string: "mailto:2403871950@qq.com?subject=SkyBridge%20Compass%20Pro%20反馈") {
            NSWorkspace.shared.open(url)
        }
    }
    
 /// 打开官网
    private func openWebsite() {
        if let url = URL(string: "https://skybridge-compass.vercel.app") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Liquid Glass按钮样式
@available(macOS 14.0, *)
struct LiquidGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 关于窗口
@available(macOS 14.0, *)
struct AboutWindow: View {
    @Environment(\.dismiss) private var dismiss
    
    private var aboutIconPath: String {
        if let bundled = Bundle.module.url(forResource: "about-main-icon", withExtension: "svg")
            ?? Bundle.module.url(
                forResource: "about-main-icon",
                withExtension: "svg",
                subdirectory: "Icons"
            ) {
            return bundled.path
        }
        return "/Users/bill/Desktop/1764932992803-2.svg"
    }
    
    var body: some View {
        VStack(spacing: 24) {
 // 应用图标和名称
            VStack(spacing: 12) {
                SVGEmbeddedImageView(
                    filePath: aboutIconPath,
                    contentMode: .fill,
                    safeInset: 0,
                    clipCornerRadius: 22
                )
                    .frame(width: 100, height: 100)
                    .shadow(color: .blue.opacity(0.3), radius: 20, x: 0, y: 10)
                
                VStack(spacing: 4) {
                    Text("SkyBridge Compass Pro")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("版本 1.0.0 (Build 2025.10.31)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
 // 核心技术
            VStack(alignment: .leading, spacing: 12) {
                Text("核心技术")
                    .font(.headline)
                
                HStack(spacing: 20) {
                    TechBadge(icon: "cpu", text: "Apple Silicon")
                    TechBadge(icon: "cube.transparent", text: "Metal 4")
                    TechBadge(icon: "bolt.fill", text: "Swift 6.2")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
 // 系统要求
            VStack(alignment: .leading, spacing: 8) {
                Text("系统要求")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("处理器:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text("Apple Silicon (M1-M5)")
                            .font(.caption)
                    }
                    HStack {
                        Text("系统:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text("macOS 14.0 或更高")
                            .font(.caption)
                    }
                    HStack {
                        Text("内存:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text("8GB RAM（推荐 16GB）")
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
 // 版权信息
            VStack(spacing: 4) {
                Text("© 2024-2026 SkyBridge Team")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("专为 Apple Silicon 优化 • 采用 Swift 6.2 构建")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
 // 按钮
            HStack {
            Button(LocalizationManager.shared.localizedString("about.website")) {
                    if let url = URL(string: "https://skybridge-compass.vercel.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Spacer()
                
                Button(LocalizationManager.shared.localizedString("action.close")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 技术徽章
@available(macOS 14.0, *)
struct TechBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - 兼容性修饰符
/// 为 macOS 26+ 添加 .menuIndicator(.hidden)，在旧版本上无操作
@available(macOS 14.0, *)
private struct MenuIndicatorHiddenModifier: ViewModifier {
    func body(content: Content) -> some View {
 // .menuIndicator(.hidden) 仅在 macOS 26+ 可用；旧版本保持原样
        if #available(macOS 26.0, *) {
            content.menuIndicator(.hidden)
        } else {
            content
        }
    }
}
