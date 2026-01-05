import SwiftUI
import SkyBridgeCore

/// 快捷操作面板
@available(macOS 14.0, *)
public struct QuickActionsPanelView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    @Binding var selectedNavigation: NavigationItem
    
    public init(selectedNavigation: Binding<NavigationItem>) {
        self._selectedNavigation = selectedNavigation
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(LocalizationManager.shared.localizedString("dashboard.quickActions"), systemImage: "square.grid.2x2")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                QuickActionButton(
                    title: LocalizationManager.shared.localizedString("action.scanDevices"),
                    icon: "magnifyingglass",
                    color: .blue
                ) {
                    appModel.triggerDiscoveryRefresh()
                }
                
                QuickActionButton(
                    title: LocalizationManager.shared.localizedString("dashboard.fileTransfer"),
                    icon: "folder",
                    color: .orange
                ) {
                    selectedNavigation = .fileTransfer
                }
                
                QuickActionButton(
                    title: LocalizationManager.shared.localizedString("action.systemMonitor"),
                    icon: "speedometer",
                    color: .green
                ) {
                    selectedNavigation = .systemMonitor
                }
                
                QuickActionButton(
                    title: LocalizationManager.shared.localizedString("action.settings"),
                    icon: "gearshape",
                    color: .gray
                ) {
                    selectedNavigation = .settings
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

