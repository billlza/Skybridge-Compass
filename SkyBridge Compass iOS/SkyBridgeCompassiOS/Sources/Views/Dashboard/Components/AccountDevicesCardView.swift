import SwiftUI
import SkyBridgeProtocolCore

/// 首页「账号设备」液态玻璃卡片：位于天气卡片之下、统计卡片之上，简要展示同一账号下的设备与在线统计。
/// iOS 只做控制端：本机行标注「仅控制端」，Mac 行标注「可被控」。
@available(iOS 17.0, *)
struct AccountDevicesCardView: View {
    @ObservedObject private var presence = AccountPresenceService.shared
    @EnvironmentObject private var authManager: AuthenticationManager

    static let previewRowLimit = 3

    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .liquidGlassCard(cornerRadius: 24, padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(RuntimeLocalization.string("账号设备")))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(RuntimeLocalization.string("账号设备"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let snapshot = presence.accountDevices {
                    let summary = AccountDevicePresentationPolicy.summary(for: snapshot.devices)
                    Text(RuntimeLocalization.format("%d 台设备 · %d 台在线", [summary.total, summary.online]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let nebulaId = authManager.currentUser?.nebulaId, !nebulaId.isEmpty {
                    Text(nebulaId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(RuntimeLocalization.string("查看全部")) {
                onViewAll()
            }
            .font(.subheadline)
            .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = presence.accountDevices {
            if let issue = AccountDevicePresentation.registrationIssueText(for: snapshot) {
                Label(issue, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let devices = Array(AccountDevicePresentationPolicy.orderedDevices(snapshot.devices).prefix(Self.previewRowLimit))
            if devices.isEmpty {
                Text(RuntimeLocalization.string("登录同一账号的其他设备会显示在这里"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(devices) { record in
                        AccountDeviceCompactRow(record: record)
                    }
                }
                if let failure = presence.lastListFailure {
                    Label(AccountDevicePresentation.failureText(failure), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.9))
                }
            }
        } else if let failure = presence.lastListFailure {
            let isSignedOut = failure == .notAuthenticated && !presence.isAuthenticated
            Label(
                isSignedOut
                    ? RuntimeLocalization.string("登录后才能看到本账号的设备")
                    : AccountDevicePresentation.failureText(failure),
                systemImage: isSignedOut ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if presence.isAuthenticated {
            HStack(spacing: 8) {
                ProgressView().tint(.cyan).scaleEffect(0.8)
                Text(RuntimeLocalization.string("正在同步账号设备…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label(RuntimeLocalization.string("登录后才能看到本账号的设备"), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@available(iOS 17.0, *)
private struct AccountDeviceCompactRow: View {
    let record: AccountDeviceRecord

    private var connectivity: AccountDevicePresentationPolicy.Connectivity {
        AccountDevicePresentationPolicy.connectivity(for: record, isLANReachable: false)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AccountDevicePresentation.systemImageName(for: record))
                .font(.system(size: 16))
                .foregroundColor(AccountDevicePresentation.statusColor(for: connectivity))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(AccountDevicePresentationPolicy.displayName(for: record))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(AccountDevicePresentation.modelText(for: record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(AccountDevicePresentation.statusColor(for: connectivity))
                        .frame(width: 6, height: 6)
                    Text(AccountDevicePresentation.statusText(for: connectivity))
                    if let address = AccountDevicePresentationPolicy.primaryAddress(for: record) {
                        Text(address).monospaced()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(AccountDevicePresentation.relativeTimeText(from: record.lastSeenAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
