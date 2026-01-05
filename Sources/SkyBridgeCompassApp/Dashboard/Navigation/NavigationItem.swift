import SwiftUI
import SkyBridgeCore

/// 导航项目枚举
public enum NavigationItem: String, CaseIterable, Identifiable {
    case dashboard = "sidebar.dashboard"
    case deviceManagement = "sidebar.deviceDiscovery"
    case usbDeviceManagement = "sidebar.usbManagement"
    case fileTransfer = "sidebar.fileTransfer"
    case remoteDesktop = "sidebar.remoteDesktop"
    case quantumCommunication = "quantum.title"
    case systemMonitor = "sidebar.systemMonitor"
 // 已移除 Apple Silicon 测试与性能演示入口
    case settings = "sidebar.settings"
    
    @MainActor
    public var localizedTitle: String {
        return LocalizationManager.shared.localizedString(self.rawValue)
    }
    
    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .dashboard: return "house"
        case .deviceManagement: return "magnifyingglass"
        case .usbDeviceManagement: return "cable.connector"
        case .fileTransfer: return "folder"
        case .remoteDesktop: return "display"
        case .quantumCommunication: return "atom"
        case .systemMonitor: return "speedometer"
        
        case .settings: return "gearshape"
        }
    }
    
 /// 导航项目对应的主题色彩
    public var color: Color {
        switch self {
        case .dashboard: return .blue
        case .deviceManagement: return .green
        case .usbDeviceManagement: return .purple
        case .fileTransfer: return .orange
        case .remoteDesktop: return .cyan
        case .quantumCommunication: return .purple
        case .systemMonitor: return .orange
        
        case .settings: return .secondary
        }
    }
}

/// 导航项目视图组件
public struct NavigationItemView: View {
    let item: NavigationItem
    let isSelected: Bool
    let action: () -> Void
    
    public init(item: NavigationItem, isSelected: Bool, action: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
 // 图标
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .white : item.color)
                    .frame(width: 20, height: 20)
                
 // 标题
                Text(item.localizedTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? item.color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

