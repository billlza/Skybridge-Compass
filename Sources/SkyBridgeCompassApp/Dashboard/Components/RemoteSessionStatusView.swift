import SwiftUI
import SkyBridgeCore

public struct RemoteSessionStatusView: View {
    let session: RemoteSessionSummary
    let action: () -> Void
    let endAction: () -> Void

    public init(session: RemoteSessionSummary, action: @escaping () -> Void, endAction: @escaping () -> Void) {
        self.session = session
        self.action = action
        self.endAction = endAction
    }

    public var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.targetName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(session.protocolDescription) • \(LocalizationManager.shared.localizedString("dashboard.session.bandwidth")) \(session.bandwidthMbps, specifier: "%.1f") Mbps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: session.frameLatencyMilliseconds, total: 80)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
            }
            Spacer()
            VStack(spacing: 8) {
                Button(LocalizationManager.shared.localizedString("dashboard.action.view")) { action() }
                    .buttonStyle(.borderedProminent)
                Button(LocalizationManager.shared.localizedString("dashboard.action.disconnect")) { endAction() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
    }
}

