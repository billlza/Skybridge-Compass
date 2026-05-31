import SwiftUI
import SkyBridgeCore
import Foundation
import Darwin

/// 液态玻璃材质侧边栏组件
/// 使用SwiftUI 4.0的最新Liquid Glass效果
@available(macOS 14.0, *)
struct GlassSidebar: View {
    @Binding var selectedTab: SidebarTab
    @State private var hoverTab: SidebarTab?
    @State private var isExpanded: Bool = true
    @Namespace private var glassNamespace
    @State private var localizedSidebarText = LocalizedSidebarText.resolve()
 // 设备信息（本机名称与CPU型号）用于在侧边栏头部展示，避免运行时频繁查询。
    @State private var localDeviceName: String = Host.current().localizedName ?? "本机"
    @State private var localCPUModel: String = ""
    
 // 用户资料状态管理
    @State private var showingUserProfile = false
    
 // 环境对象
    @EnvironmentObject var authModel: AuthenticationViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var sidebarTabs: [SidebarTab] {
        localizedSidebarText.tabs
    }
    
    var body: some View {
        VStack(spacing: 0) {
 // 顶部标题区域
            headerSection
            
            Divider()
                .background(Color.white.opacity(0.2))
                .padding(.horizontal, 16)
            
 // 导航项目列表
            navigationSection
            
            Spacer()
            
 // 底部用户信息区域 - 使用新的Liquid Glass设计
            LiquidGlassUserArea(showingUserProfile: $showingUserProfile)
                .environmentObject(authModel)
                .environmentObject(themeConfiguration)
        }
        .frame(width: isExpanded ? 280 : 80)
        .background(
 // 使用液态玻璃效果作为背景
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 0)
        )
        .overlay(
 // 右侧边框
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color.white.opacity(0.1)),
            alignment: .trailing
        )
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isExpanded)
        .background(
            Group {
                if showingUserProfile {
                    Color.clear
                        .onAppear {
 // 不再弹出窗口，而是通过父组件的状态管理显示覆盖层
                            SkyBridgeLogger.ui.debugOnly("🎯 [GlassSidebar] 用户资料状态已激活，等待父组件处理")
                        }
                }
            }
        )
        .onAppear(perform: refreshLocalizedSidebarText)
        .onChange(of: localizationManager.currentLanguage) { _, _ in
            refreshLocalizedSidebarText()
        }
        .task {
 // 在视图加载时一次性提取设备名称与CPU型号，避免在主线程上同步sysctl导致卡顿。
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let cpu = await Task.detached(priority: .utility) { queryCPUModelString() }.value
            await MainActor.run {
                self.localDeviceName = deviceName
                self.localCPUModel = cpu
            }
        }
    }
    
 // MARK: - macOS 原生窗口管理
 /// 打开用户资料的原生窗口
 /// 使用macOS 14+的窗口样式和材质效果
    private func openUserProfileWindow() {
 // 创建用户资料窗口内容
        let userProfileWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
 // 配置macOS窗口样式
        userProfileWindow.title = "用户资料"
        userProfileWindow.center()
        userProfileWindow.setFrameAutosaveName("UserProfileWindow")
        
 // 设置macOS窗口特性：材质和透明度（macOS 11+）
        userProfileWindow.titlebarAppearsTransparent = true
        userProfileWindow.toolbarStyle = .unified
        
 // 使用macOS 15+的增强材质效果（如果可用）
        if #available(macOS 15.0, *) {
            userProfileWindow.contentView?.wantsLayer = true
            userProfileWindow.contentView?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        
 // 创建SwiftUI内容视图
        let contentView = NSHostingView(rootView: 
            UserProfileView()
                .environmentObject(authModel)
                .environmentObject(themeConfiguration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
        )
        
        userProfileWindow.contentView = contentView
        userProfileWindow.makeKeyAndOrderFront(nil)
        
 // 重置状态 - 使用Task替代DispatchQueue以符合Swift 6.2最佳实践
        Task { @MainActor in
            showingUserProfile = false
        }
    }

    private func refreshLocalizedSidebarText() {
        localizedSidebarText = LocalizedSidebarText.resolve()
    }
    
 // MARK: - 头部区域
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
 // 应用图标
                BrandAppIconView(
                    contentMode: .fit,
                    safeInset: 1,
                    clipCornerRadius: 12,
                    preferredResourceName: "SidebarBrandIcon"
                )
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color(red: 0.16, green: 0.58, blue: 1.0).opacity(0.28),
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: Color(red: 0.08, green: 0.52, blue: 1.0).opacity(0.34), radius: 10, x: 0, y: 2)
                .shadow(color: Color(red: 0.95, green: 0.72, blue: 0.34).opacity(0.12), radius: 5, x: 0, y: 0)
                .shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 1)
                
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedSidebarText.appName)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text(localizedSidebarText.appSlogan)
                            .font(.caption)
                            .foregroundColor(.secondary)
 // 在应用名右侧展示本机设备名称与CPU型号，使用单行紧凑样式。
                        Text("\(localDeviceName) · \(localCPUModel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }

 // MARK: - 设备/CPU信息查询
    
 // MARK: - 导航区域
    private var navigationSection: some View {
        VStack(spacing: 4) {
            ForEach(sidebarTabs, id: \.id) { tab in
                SidebarTabButton(
                    tab: tab,
                    isSelected: selectedTab.id == tab.id,
                    isHovered: hoverTab?.id == tab.id,
                    isExpanded: isExpanded,
                    namespace: glassNamespace
                ) {
                    guard selectedTab.id != tab.id else { return }
                    selectedTab = tab
                }
                .onHover { hovering in
                    hoverTab = hovering ? tab : nil
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
    }
}

// MARK: - 侧边栏本地化快照
private struct LocalizedSidebarText: Equatable {
    let appName: String
    let appSlogan: String
    let tabs: [SidebarTab]

    @MainActor
    static func resolve() -> LocalizedSidebarText {
        let localizationManager = LocalizationManager.shared
        let quantumTitle = localizationManager.localizedString("quantum.title")
        return LocalizedSidebarText(
            appName: localizationManager.localizedString("app.name"),
            appSlogan: localizationManager.localizedString("app.slogan"),
            tabs: [
                SidebarTab(id: "sidebar.dashboard", title: localizationManager.localizedString("sidebar.dashboard"), icon: "house", color: .blue),
                SidebarTab(id: "sidebar.deviceDiscovery", title: localizationManager.localizedString("sidebar.deviceDiscovery"), icon: "magnifyingglass", color: .green),
                SidebarTab(id: "sidebar.usbManagement", title: localizationManager.localizedString("sidebar.usbManagement"), icon: "cable.connector", color: .indigo),
                SidebarTab(id: "sidebar.fileTransfer", title: localizationManager.localizedString("sidebar.fileTransfer") + "（" + quantumTitle + "）", icon: "folder", color: .orange),
                SidebarTab(id: "sidebar.remoteDesktop", title: localizationManager.localizedString("sidebar.remoteDesktop") + "（" + quantumTitle + "）", icon: "display", color: .cyan),
                SidebarTab(id: "sidebar.systemMonitor", title: localizationManager.localizedString("sidebar.systemMonitor"), icon: "speedometer", color: .orange),
                SidebarTab(id: "sidebar.settings", title: localizationManager.localizedString("sidebar.settings"), icon: "gearshape", color: .secondary)
            ]
        )
    }
}

// MARK: - 顶层工具函数（非MainActor隔离）
/// 查询CPU型号字符串。优先使用 `machdep.cpu.brand_string`，在Apple Silicon上可返回如“Apple M3/M4”。
/// 若不可用则回退到 `hw.model`（例如“MacBookPro18,3”）。该方法为纯函数，避免UI主线程阻塞。
fileprivate func queryCPUModelString() -> String {
    if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty, brand.lowercased() != "apple processor" {
        return brand
    }
    if let model = sysctlString("hw.model"), !model.isEmpty {
        return model
    }
    return "CPU"
}

/// 安全读取sysctl字符串值为Swift字符串，使用推荐的解码方式替代cString。
fileprivate func sysctlString(_ name: String) -> String? {
    var size: size_t = 0
 // 先查询长度
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(size))
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
 // size包含结尾的\0，解码时去掉末尾的空字节
    return String(decoding: buffer.dropLast(), as: UTF8.self)
}

// MARK: - 侧边栏标签数据模型
struct SidebarTab: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    
    static func == (lhs: SidebarTab, rhs: SidebarTab) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - 侧边栏标签按钮
struct SidebarTabButton: View {
    let tab: SidebarTab
    let isSelected: Bool
    let isHovered: Bool
    let isExpanded: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
 // 图标
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .white : tab.color)
                    .frame(width: 20, height: 20)
                
                if isExpanded {
 // 标题
                    Text(tab.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Group {
                    if isSelected {
 // 选中状态背景
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedTabGradient(for: tab.color))
                            .matchedGeometryEffect(id: "selectedTab", in: namespace)
                    } else if isHovered {
 // 悬停状态背景
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: isSelected)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
    
 /// ✅ 兼容性：为选中标签生成渐变（macOS 14+ 使用 .gradient 优先，旧版使用 LinearGradient）
    private func selectedTabGradient(for color: Color) -> some ShapeStyle {
        if #available(macOS 14.0, *) {
            return AnyShapeStyle(color.gradient)
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [color, color.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}


struct GlassSidebar_Previews: PreviewProvider {
    static var previews: some View {
        if #available(macOS 14.0, *) {
            HStack(spacing: 0) {
                GlassSidebar(selectedTab: .constant(
                    SidebarTab(id: "dashboard", title: "仪表板", icon: "chart.bar.fill", color: .blue)
                ))
                .environmentObject(AuthenticationViewModel())
                .environmentObject(ThemeConfiguration.shared)
                
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
            }
            .frame(height: 600)
        } else {
            Text("需要 macOS 14.0 或更高版本")
        }
    }
}
