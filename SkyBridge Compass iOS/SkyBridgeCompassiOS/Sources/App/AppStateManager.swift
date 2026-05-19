import SwiftUI

/// 应用状态管理器
@MainActor
class AppStateManager: ObservableObject {
    @Published var isSetupComplete: Bool = false
    @Published var currentTab: Tab = .discovery
    @Published var isConnected: Bool = false
    @Published var activeConnections: [Connection] = []

    enum Tab: Int, CaseIterable {
        case discovery = 0
        case remoteDesktop = 1
        case fileTransfer = 2
        case settings = 3

        @MainActor
        var title: String {
            let l10n = LocalizationManager.instance
            switch self {
            case .discovery: return l10n.localized("tab.discovery")
            case .remoteDesktop: return l10n.localized("tab.remote")
            case .fileTransfer: return l10n.localized("tab.files")
            case .settings: return l10n.localized("tab.settings")
            }
        }

        var icon: String {
            switch self {
            case .discovery: return "wifi.circle.fill"
            case .remoteDesktop: return "display"
            case .fileTransfer: return "doc.on.doc.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }
}
