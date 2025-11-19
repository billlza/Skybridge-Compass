import SwiftUI
import Observation
import SkyBridgeCore
import SkyBridgeDesignSystem

struct RootView: View {
    @Bindable var appState: SkybridgeAppState

    var body: some View {
        ZStack(alignment: .bottom) {
            SkyBridgeBackground()
            VStack(spacing: 0) {
                TopStatusBar(
                tab: appState.selectedTab,
                linkSummary: appState.dashboardSummary.linkSummary
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                TabView(selection: $appState.selectedTab) {
                    DashboardTabView(appState: appState)
                        .tag(MainTab.dashboard)
                    DiscoveryTabView(devices: appState.devices)
                        .tag(MainTab.discovery)
                    FileTransferTabView(transfers: appState.transfers)
                        .tag(MainTab.fileTransfer)
                    RemoteDesktopTabView(sessions: appState.sessions)
                        .tag(MainTab.remoteDesktop)
                    SettingsTabView(performance: appState.performanceSettings, security: appState.securityStatus)
                        .tag(MainTab.settings)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appState.selectedTab)
            }

            FloatingTabBar(selected: $appState.selectedTab)
                .padding(.horizontal, 24)
                .padding(.bottom, safeAreaBottomInset() == 0 ? 16 : safeAreaBottomInset())
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .bottom)
        .task {
            await appState.refreshWeather()
        }
    }
}

struct TopStatusBar: View {
    let tab: MainTab
    let linkSummary: NetworkLinkSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("当前链路：\(linkSummary.primary.label) · \(linkSummary.primary.latency)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                StatusDot(color: .green)
                Text("在线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct FloatingTabBar: View {
    @Binding var selected: MainTab

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        selected = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(selected == tab ? Color.white : Color.white.opacity(0.6))
                    .background(
                        ZStack {
                            if selected == tab {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(liquidGlassMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 30, x: 0, y: 12)
    }

    @Namespace private var namespace
}
