import SwiftUI

/// 液态玻璃材质侧边栏组件
/// 使用SwiftUI 4.0的最新Liquid Glass效果
struct GlassSidebar: View {
    @Binding var selectedTab: SidebarTab
    @State private var hoverTab: SidebarTab?
    @State private var isExpanded: Bool = true
    @Namespace private var glassNamespace
    
    let sidebarTabs: [SidebarTab] = [
        SidebarTab(id: "主控制台", title: "主控制台", icon: "house", color: .blue),
        SidebarTab(id: "设备发现", title: "设备发现", icon: "magnifyingglass", color: .green),
        SidebarTab(id: "文件传输", title: "文件传输", icon: "folder", color: .orange),
        SidebarTab(id: "远程桌面", title: "远程桌面", icon: "display", color: .cyan),
        SidebarTab(id: "系统监控", title: "系统监控", icon: "speedometer", color: .orange),
        SidebarTab(id: "Apple Silicon 测试", title: "Apple Silicon 测试", icon: "cpu", color: .red),
        SidebarTab(id: "性能演示", title: "性能演示", icon: "play.circle", color: .purple),
        SidebarTab(id: "设置", title: "设置", icon: "gearshape", color: .secondary)
    ]
    
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
            
            // 底部用户信息区域
            footerSection
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
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: selectedTab)
    }
    
    // MARK: - 头部区域
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                // 应用图标
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue, .purple]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "network")
                            .font(.title2)
                            .foregroundColor(.white)
                    )
                
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SkyBridge")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Compass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                
                Spacer()
                
                // 折叠/展开按钮
                Button(action: {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }
    
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
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                        selectedTab = tab
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hoverTab = hovering ? tab : nil
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
    }
    
    // MARK: - 底部区域
    private var footerSection: some View {
        VStack(spacing: 12) {
            Divider()
                .background(Color.white.opacity(0.2))
                .padding(.horizontal, 16)
            
            HStack {
                // 用户头像
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.green, .blue]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text("U")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    )
                
                if isExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("用户")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("已连接")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                
                Spacer()
                
                if isExpanded {
                    Button(action: {}) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - 侧边栏标签页数据模型
struct SidebarTab: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let color: Color
}

// MARK: - 侧边栏按钮组件
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
                        // 选中状态的液态玻璃背景
                        RoundedRectangle(cornerRadius: 10)
                            .fill(tab.color.gradient)
                            .matchedGeometryEffect(id: "selectedTab", in: namespace)
                    } else if isHovered {
                        // 悬停状态的液态玻璃背景
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
}

// MARK: - 玻璃按钮样式
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    HStack(spacing: 0) {
        GlassSidebar(selectedTab: .constant(
            SidebarTab(id: "dashboard", title: "仪表板", icon: "chart.bar.fill", color: .blue)
        ))
        
        Rectangle()
            .fill(Color.gray.opacity(0.1))
    }
    .frame(height: 600)
}