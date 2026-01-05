import SwiftUI
import SkyBridgeCore

/// 远程会话面板
@available(macOS 14.0, *)
public struct RemoteSessionsPanelView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    @Binding var selectedSession: RemoteSessionSummary?
    
    public init(selectedSession: Binding<RemoteSessionSummary?>) {
        self._selectedSession = selectedSession
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(LocalizationManager.shared.localizedString("dashboard.remoteSessions"), systemImage: "display.2")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(spacing: 16) {
                if appModel.sessions.isEmpty {
                    EmptyStateView(
                        title: LocalizationManager.shared.localizedString("session.noActive"),
                        subtitle: LocalizationManager.shared.localizedString("session.placeholder")
                    )
                } else {
                    ForEach(appModel.sessions, id: \.id) { session in
                        RemoteSessionStatusView(
                            session: session,
                            action: { selectedSession = session },
                            endAction: { 
 // 符合Swift 6.2.1最佳实践：terminate是同步方法，不需要await
                                appModel.terminate(session: session)
                            }
                        )
                    }
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

