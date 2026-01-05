import SwiftUI
import SkyBridgeCore

public struct RemoteSessionRow: View {
    let session: RemoteSessionSummary

    public init(session: RemoteSessionSummary) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.targetName)
                .font(.headline)
            Text(session.protocolDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

